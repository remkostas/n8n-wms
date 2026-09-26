# Benchmark

Two sets of numbers, measured in different ways. Both are kept, because the difference between them is a finding in its own right.

1. **The original evaluation** (July 2026, n8n 2.31.6): *probe* workflows of 1–4 nodes, built to isolate what each layer costs. This decided whether the architecture was fast enough to be worth building at all.
2. **This repo** (September 2026, n8n 2.40.7): the *real* terminal, driven by [`bench/bench.py`](../bench/bench.py) exactly as an operator's browser drives it.

---

## 1. Original evaluation: where the time goes

Hardware: a 16-core mini PC, nothing else under load. Four targets returning the same ~4 KB screen, so the only variable is how much machinery ran:

| layer | p50 ms | delta |
|---|---:|---:|
| network + host floor (static nginx) | 0.1 | |
| + n8n webhook execution | 28 | **+28** |
| + Code node (render HTML) | 32 | +4 |
| + Postgres lookup | 34 | +2 |
| + atomic write in a `plpgsql` function | 37 | +3 |

**n8n's fixed per-request cost is the whole story.** Accepting a webhook, starting an execution and responding costs about 28 ms; rendering the HTML and querying the database cost 6 ms together. PostgreSQL itself spent 0.016 ms executing the lookup.

### How many operators

Raw concurrency is an abstraction; the number that matters is *operators*. Each simulated operator scans on average once every 5 s (brisk for warehouse work), with Poisson arrivals. On the 4-node write probe:

| operators | p50 ms | p95 ms | p99 ms | errors |
|---:|---:|---:|---:|---:|
| 5 | 36 | 44 | 46 | 0 |
| 10 | 36 | 47 | 62 | 0 |
| 25 | 36 | 52 | 177 | 0 |
| 50 | 36 | 58 | 173 | 0 |
| 85 | 42 | 150 | 430 | 0 |
| 100 | 44 | 277 | 558 | 0 |

p95 stayed under 200 ms up to about 85 operators, and there were **no errors at any level**, even at 200 operators. n8n queues instead of dropping, so saturation shows up as slowness, not failures. That means a deployment needs latency monitoring, not just uptime checks.

The ceiling is throughput: about 45–50 executions/s, because n8n runs everything in one process unless you set up queue mode with workers.

### Correctness under contention

400 requests at concurrency 20, all writing *the same article*, from a zero baseline:

```
requests ok = 400   errors = 0
on_hand = 400   ledger_rows = 400   ledger_sum = 400
```

No lost updates. The row lock serialises the writers correctly.

### Tuning levers

- **`EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`**: about 15 % faster and 16 % more throughput. Useful, not decisive. At warehouse volumes (30 operators ≈ 170,000 executions a day) an aggressive `EXECUTIONS_DATA_MAX_AGE` matters more.
- **Node's 5 s keep-alive timeout** is almost exactly a picker's gap between scans, so most real scans pay for a new TCP connection. Browsers hide this. A custom scanner client would need to handle it.

---

## 2. This repo: the real terminal

Same 16-core mini PC, host otherwise idle, n8n 2.40.7 with default settings (every execution saved), PostgreSQL 16. The compose file has since moved to PostgreSQL 17, because n8n 2.40 warns that 16 is outside its supported range; the contention result below was re-checked on 17, on different hardware, and is still exact. The latency numbers were not re-measured.

**A single screen** (GET with a live session: webhook → `screen_data` → render):

| concurrency | p50 ms | p95 ms | p99 ms | req/s | errors |
|---:|---:|---:|---:|---:|---:|
| 1 | 50 | 63 | 78 | 19 | 0 |
| 5 | 177 | 244 | 607 | 26 | 0 |
| 10 | 343 | 397 | 621 | 28 | 0 |

**Operators**, same model as above (one scan per 5 s on average, Poisson arrivals, 60 s per level). Latency is what the operator waits for: the scan POST *plus* the next screen:

| operators | p50 ms | p95 ms | p99 ms | max ms | errors |
|---:|---:|---:|---:|---:|---:|
| 5 | 127 | 494 | 1144 | 1183 | 0 |
| 10 | 127 | 238 | 318 | 356 | 0 |
| 25 | 161 | 312 | 583 | 686 | 0 |
| 35 | 211 | 527 | 596 | 652 | 0 |
| 50 | 335 | 1573 | 1986 | 2029 | 0 |

**Contention**, 10 operators × 40 scans receiving the same article on the same order line through the full HTTP path:

```
scans ok = 400   errors = 0
on_hand = 400   ledger_rows = 400   ledger_sum = 400   received_qty = 400
```

### Why the real terminal is about 3× slower than the probes

A probe was one execution of 1–4 nodes. A real scan is **two executions and 16 node runs**: the Scan Handler (read request, load session, resolve barcode, decide, mutate, save state, build redirect) and then the Operator Terminal rendering the next screen. n8n's per-execution and per-node overhead is paid for all of it. n8n's own execution data shows Code nodes at 6–12 ms each on 2.40.7, against about 4 ms on the 2.31.6 probes. The database calls are still small.

What that changes:

- **Per scan: about 130 ms instead of 36 ms.** Still fast enough to feel instant on a handheld.
- **Ceiling: about 25–35 operators instead of 85.** p95 stays around half a second up to 35 operators and passes 1.5 s at 50. An SME warehouse (5–30 operators) still fits, but with little headroom rather than a lot.
- **Tails are noisy.** Even at 5 operators the occasional scan takes about a second. I haven't isolated the cause; the p50 doesn't move.
- **Still no errors at any level**, and still exact under contention.

The verdict doesn't change: speed was never what ruled the product out. The margin is smaller than the probe numbers suggested, though, which is exactly why the real system had to be measured too.

---

## 3. Two harness bugs, fixed before any of this meant anything

Both produced confident, plausible, wrong numbers, and the first would have flipped the verdict.

**Operators in lockstep.** The first operator model gave everyone a fixed 5 s think time and started them together. Ten operators then fired as one burst of ten requests followed by five idle seconds, and the harness reported p95 266 ms for an almost idle system. The giveaway was that it looked four times worse than an open-loop run at fifteen times the load. Fixed with random start offsets and exponentially distributed gaps (a Poisson process, which is what independent workers are).

**Keep-alive closures counted as failures.** Once arrivals were spread out, about half the requests failed with `RemoteDisconnected`: the harness was reusing sockets n8n had already closed after its 5 s timeout. The server had answered everything correctly. Fixed by retrying once on a dropped connection, as any real HTTP client does.

Both bugs had the same signature: the load generator was measuring itself. **A result that contradicts a simpler measurement is a harness bug until proven otherwise.** `bench/bench.py` has both fixes built in.

## Reproducing

```bash
bench/bench.py screen     --levels 1,5,10 -n 300
bench/bench.py operators  --levels 5,10,25,50 --think 5 --duration 30
bench/bench.py contention --workers 10 --per-worker 40     # resets the database afterwards
```

Run them on a quiet machine. Anything else competing for CPU shows up directly in the tail.
