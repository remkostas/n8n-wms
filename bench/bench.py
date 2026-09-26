#!/usr/bin/env python3
"""Load and correctness benchmark for the n8n-wms terminal. Standard library only.

Three measurements, all against the real terminal workflows (not probes):

  screen      GET of the operator screen with a live session: webhook -> one
              SQL call (wms.screen_data) -> HTML render. Closed loop at fixed
              concurrency levels.

  operators   The number that actually matters. Each simulated operator scans
              about once every --think seconds (Poisson arrivals, random start
              offset) doing lookups: POST the scan, follow the 303, GET the next
              screen. Reports the round trip an operator waits for.

  contention  Correctness, not speed. N operators receive the SAME article on
              the SAME purchase-order line at once, one unit per scan, through
              the full HTTP path. Afterwards on-hand, ledger rows, ledger sum
              and received_qty must all equal the number of scans exactly.

Two lessons from the first version of this harness are built in, because both
produced confident, wrong numbers (docs/BENCHMARK.md section 5):
  * operators start at random offsets with exponential gaps; fixed think times
    lock them into lockstep bursts and measure the harness, not the server;
  * a request that dies on a connection the server already closed (n8n's
    keep-alive timeout is 5 s, about one scan gap) is retried once, as any real
    client does, instead of being counted as a failure.

`contention` adds bench rows to the database and resets it afterwards with
scripts/reset-db.sh, so it is destructive like the acceptance test.

Usage:
  bench/bench.py screen     [--levels 1,5,10] [-n 200]
  bench/bench.py operators  [--levels 5,10,25] [--think 5] [--duration 30]
  bench/bench.py contention [--workers 20] [--per-worker 20]
"""
import argparse
import http.client
import os
import random
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env():
    env = {}
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    env.update({k: v for k, v in os.environ.items() if k in env or k.startswith(("N8N_", "POSTGRES_"))})
    return env


ENV = load_env()
HOSTPORT = ENV.get("N8N_BIND", "127.0.0.1:5678")
HOST, PORT = HOSTPORT.rsplit(":", 1)
PORT = int(PORT)


def sql(query):
    """Run one query through the same psql helper the shell scripts use."""
    out = subprocess.run(
        ["bash", "-c", '. "$0/scripts/lib.sh"; wms_sql "$1"', ROOT, query],
        capture_output=True, text=True, check=True)
    return out.stdout.strip()


class Client:
    """One operator: one keep-alive connection, one session cookie."""

    def __init__(self):
        self.conn = None
        self.cookie = ""

    def _request(self, method, path, body=None):
        headers = {"Cookie": self.cookie} if self.cookie else {}
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        for attempt in (1, 2):
            if self.conn is None:
                self.conn = http.client.HTTPConnection(HOST, PORT, timeout=30)
            try:
                self.conn.request(method, path, body=body, headers=headers)
                resp = self.conn.getresponse()
                data = resp.read()
                return resp, data
            except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError):
                # Server closed the idle keep-alive socket; reconnect once.
                self.conn.close()
                self.conn = None
                if attempt == 2:
                    raise

    def get_screen(self, path="/webhook/wms"):
        resp, data = self._request("GET", path)
        if resp.status != 200:
            raise RuntimeError(f"screen returned {resp.status}")
        return data.decode()

    def scan(self, action, code=""):
        """POST a scan, follow the 303 like a browser. Returns the next screen."""
        body = urllib.parse.urlencode({"action": action, "code": code})
        resp, _ = self._request("POST", "/webhook/wms/scan", body)
        if resp.status != 303:
            raise RuntimeError(f"scan returned {resp.status}")
        m = re.search(r"wms_session=([^;]*)", resp.getheader("Set-Cookie") or "")
        if m and m.group(1):
            self.cookie = "wms_session=" + m.group(1)
        loc = urllib.parse.urlsplit(resp.getheader("Location") or "/webhook/wms")
        return self.get_screen(loc.path + ("?" + loc.query if loc.query else ""))

    def login(self, badge):
        page = self.scan("login", badge)
        if "Signed in as" not in page:
            raise RuntimeError(f"login failed for {badge}")


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))]


def row(label, times_ms, errors, wall):
    print(f"{label:>10} | {pct(times_ms, 50):7.0f} | {pct(times_ms, 95):7.0f} | "
          f"{pct(times_ms, 99):7.0f} | {max(times_ms):7.0f} | {len(times_ms) / wall:7.1f} | {errors:6d}")


HEADER = f"{'':>10} | {'p50 ms':>7} | {'p95 ms':>7} | {'p99 ms':>7} | {'max ms':>7} | {'req/s':>7} | {'errors':>6}"


# ---------------------------------------------------------------- screen

def bench_screen(levels, n):
    print("screen: GET operator menu with a live session (read path)\n")
    print(f"{'conc.':>10}" + HEADER[10:])
    for level in levels:
        clients = [Client() for _ in range(level)]
        for c in clients:
            c.login("BADGE-1001")
        times, errors, lock = [], [0], threading.Lock()
        per = max(1, n // level)

        def worker(c):
            for _ in range(per):
                t0 = time.perf_counter()
                try:
                    c.get_screen()
                    with lock:
                        times.append((time.perf_counter() - t0) * 1000)
                except Exception:
                    with lock:
                        errors[0] += 1

        t0 = time.perf_counter()
        threads = [threading.Thread(target=worker, args=(c,)) for c in clients]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        row(str(level), times, errors[0], time.perf_counter() - t0)


# ---------------------------------------------------------------- operators

def bench_operators(levels, think, duration):
    print(f"operators: Poisson scans, one every {think:g} s per operator on average;"
          f" {duration:g} s per level.\nLatency = scan POST + next-screen GET.\n")
    print(f"{'operators':>10}" + HEADER[10:])
    badges = ["BADGE-1001", "BADGE-1002", "BADGE-1003"]
    for level in levels:
        times, errors, lock = [], [0], threading.Lock()
        deadline = time.perf_counter() + duration

        def operator(i):
            c = Client()
            c.login(badges[i % len(badges)])
            c.scan("start_lookup")
            time.sleep(random.uniform(0, think))          # desynchronise start
            while time.perf_counter() < deadline:
                t0 = time.perf_counter()
                try:
                    c.scan("lookup_item", f"40000000010{random.randint(1, 12):02d}")
                    with lock:
                        times.append((time.perf_counter() - t0) * 1000)
                except Exception:
                    with lock:
                        errors[0] += 1
                time.sleep(random.expovariate(1 / think))  # Poisson arrivals

        t0 = time.perf_counter()
        threads = [threading.Thread(target=operator, args=(i,)) for i in range(level)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        if times:
            row(str(level), times, errors[0], time.perf_counter() - t0)


# ---------------------------------------------------------------- contention

def bench_contention(workers, per_worker):
    total = workers * per_worker
    print(f"contention: {workers} operators x {per_worker} scans, all receiving the same"
          f" article on the same PO line ({total} receipts)\n")
    # A bench PO with one huge line, and one badge per worker: sessions are per
    # badge, so sharing a badge would mean sharing a state machine.
    sql("""
      INSERT INTO wms.purchase_orders (order_number, vendor, warehouse_id)
           VALUES ('PO-BENCH', 'Bench', 1);
      INSERT INTO wms.purchase_order_lines (purchase_order_id, line_number, product_id, ordered_qty)
           SELECT id, 1, 12, 1000000 FROM wms.purchase_orders WHERE order_number = 'PO-BENCH';
      INSERT INTO wms.barcode_mappings (barcode, entity_type, entity_id)
           SELECT 'PO-BENCH', 'purchase_order', id FROM wms.purchase_orders WHERE order_number = 'PO-BENCH';
      INSERT INTO wms.users (badge_code, name)
           SELECT 'BENCH-' || g, 'Bench ' || g FROM generate_series(1, %d) g;
      INSERT INTO wms.barcode_mappings (barcode, entity_type, entity_id)
           SELECT badge_code, 'user', id FROM wms.users WHERE badge_code LIKE 'BENCH-%%';
      SELECT 1
    """ % workers)
    clients = []
    for i in range(1, workers + 1):
        c = Client()
        c.login(f"BENCH-{i}")
        c.scan("start_receive")
        c.scan("receive_po", "PO-BENCH")
        clients.append(c)

    errors, lock, start = [0], threading.Lock(), threading.Barrier(workers)

    def worker(c):
        start.wait()                                    # everyone at once
        for _ in range(per_worker):
            try:
                c.scan("receive_item", "4000000001012")
                page = c.scan("receive_qty", "1")
                if "Received" not in page:
                    raise RuntimeError("receipt not confirmed")
            except Exception:
                with lock:
                    errors[0] += 1

    t0 = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(c,)) for c in clients]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0

    on_hand = sql("SELECT COALESCE(sum(qty),0) FROM wms.inventory i JOIN wms.locations l ON l.id = i.location_id"
                  " WHERE i.product_id = 12 AND l.code = 'DOCK-IN'")
    rows = sql("SELECT count(*) FROM wms.inventory_transactions WHERE product_id = 12 AND reason = 'receipt'")
    ledger = sql("SELECT COALESCE(sum(delta),0) FROM wms.inventory_transactions WHERE product_id = 12 AND reason = 'receipt'")
    received = sql("SELECT received_qty FROM wms.purchase_order_lines l JOIN wms.purchase_orders po"
                   " ON po.id = l.purchase_order_id WHERE po.order_number = 'PO-BENCH'")
    print(f"scans ok = {total - errors[0]}   errors = {errors[0]}   ({wall:.1f} s)")
    print(f"on_hand = {on_hand}   ledger_rows = {rows}   ledger_sum = {ledger}   received_qty = {received}")
    exact = {on_hand, rows, ledger, received} == {str(total - errors[0])}
    print("EXACT: no lost updates" if exact else "MISMATCH: ledger and stock disagree")
    subprocess.run([os.path.join(ROOT, "scripts", "reset-db.sh")], check=True, stdout=subprocess.DEVNULL)
    return exact and errors[0] == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["screen", "operators", "contention"])
    ap.add_argument("--levels", default=None, help="comma-separated concurrency or operator counts")
    ap.add_argument("-n", type=int, default=200, help="screen: requests per level")
    ap.add_argument("--think", type=float, default=5.0, help="operators: mean seconds between scans")
    ap.add_argument("--duration", type=float, default=30.0, help="operators: seconds per level")
    ap.add_argument("--workers", type=int, default=20)
    ap.add_argument("--per-worker", type=int, default=20)
    a = ap.parse_args()
    if a.mode == "screen":
        bench_screen([int(x) for x in (a.levels or "1,5,10").split(",")], a.n)
    elif a.mode == "operators":
        bench_operators([int(x) for x in (a.levels or "5,10,25").split(",")], a.think, a.duration)
    else:
        sys.exit(0 if bench_contention(a.workers, a.per_worker) else 1)


if __name__ == "__main__":
    main()
