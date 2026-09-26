# Test cases you can run yourself

Everything needed to exercise the terminal by hand: the reference data, step-by-step cases with expected results, and the SQL that proves the database agrees with the screen.

**Terminal:** `http://localhost:5678/webhook/wms` (or whatever `N8N_BIND` is set to in `.env`).

**Database:** `psql -h 127.0.0.1 -p 55432 -U wms -d wms`, or `docker compose exec postgres psql -U wms -d wms`.

In the tables below, **auto** means `tests/walkthrough.sh` checks it and **manual** means only a person can.

---

## Before you start

**Reset to the known state.** Every case assumes clean demo data:

```bash
scripts/reset-db.sh
```

**Run the automated suite** (resets itself, safe to re-run):

```bash
tests/walkthrough.sh
```

> **Don't run the suite or a reset while somebody is using the terminal.** Both
> drop the whole `wms` schema, which deletes every live session, and anyone with
> the page open gets "Session expired. Scan your badge again." halfway through a
> task. It looks exactly like a session-timeout bug and isn't one.
>
> **Two people testing at once should use different badges.** `wms.session_start()`
> deliberately *reuses* the existing session for a badge; that's what makes "carry
> on from another handheld" work. The side effect is that two testers sharing
> `BADGE-1001` share one session and move each other's state around.

**There is one input field, named `code`, on every screen.** It takes badges, barcodes **and quantities**. That's deliberate: a handheld scanner is a keyboard that types into whatever has focus, so the box must never move or change name. Entering a quantity means typing `25` and pressing Enter.

---

## Reference data (clean seed)

### Badges
| Barcode | Name | Role |
|---|---|---|
| `BADGE-1001` | Marijke Bakker | operator |
| `BADGE-1002` | Tom de Vries | operator |
| `BADGE-1003` | Sara Yilmaz | supervisor |

The sign-in screen also has one-click buttons for all three.

### Products
| Barcode | SKU | Name | Stock | Location |
|---|---|---|---|---|
| `4000000001001` | SKU-1001 | Hex bolt M8x40 | 48 | A-01-1 |
| `4000000001002` | SKU-1002 | Hex nut M8 | 120 | A-01-2 |
| `4000000001003` | SKU-1003 | Washer M8 | 90 | A-02-1 |
| `4000000001004` | SKU-1004 | Cable tie 200mm | 36 | A-02-2 |
| `4000000001005` | SKU-1005 | Cable tie 300mm | 24 | B-01-1 |
| `4000000001006` | SKU-1006 | Insulation tape 19mm | 75 | B-01-2 |
| `4000000001007` | SKU-1007 | Wire ferrule 1.5mm | 12 | B-02-1 |
| `4000000001008` | SKU-1008 | Terminal block 6-way | 60 | B-02-2 |
| `4000000001009` | SKU-1009 | DIN rail 35mm | 8 | C-01-1 |
| `4000000001010` | SKU-1010 | Cable gland M20 | 44 | C-01-2 |
| `4000000001011` | SKU-1011 | Heat shrink 6mm | none | |
| `4000000001012` | SKU-1012 | Junction box IP65 | none | |

### Locations
Shelf barcodes are `LOC-` + code, so `A-01-2` scans as `LOC-A-01-2`. Bins: `A-01-1`, `A-01-2`, `A-02-1`, `A-02-2`, `B-01-1`, `B-01-2`, `B-02-1`, `B-02-2`, `C-01-1`, `C-01-2`. Special: `DOCK-IN` (receiving), `DOCK-OUT` (shipping), `STAGE-01` (staging).

### Purchase order `PO-1042` (barcode `PO-1042`)
| Line | SKU | Article | Ordered | Received | Open |
|---|---|---|---|---|---|
| 1 | SKU-1001 | Hex bolt M8x40 | 60 | 60 | **0, closed** |
| 2 | SKU-1004 | Cable tie 200mm | 120 | 0 | 120 |
| 3 | SKU-1007 | Wire ferrule 1.5mm | 200 | 0 | 200 |
| 4 | SKU-1011 | Heat shrink 6mm | 48 | 0 | 48 |
| 5 | SKU-1012 | Junction box IP65 | 30 | 0 | 30 |

### Sales order `SO-2075`: 3 open pick tasks
| Task | SKU | Article | Location | Requested | On the shelf |
|---|---|---|---|---|---|
| 1 | SKU-1002 | Hex nut M8 | A-01-2 | 20 | 120 |
| 2 | SKU-1006 | Insulation tape 19mm | B-01-2 | 15 | 75 |
| 3 | SKU-1009 | DIN rail 35mm | C-01-1 | 10 | **8: deliberate short pick** |

Tasks are handed out in walking order (`pick_sequence`), so task 1 comes first.

---

## A. Sign-in and sessions

| # | | Steps | Expected |
|---|---|---|---|
| A1 | auto | Open the terminal without signing in | Sign-in screen |
| A2 | auto | Scan `BADGE-9999` | "Badge not recognised." **No session row created**: `SELECT count(*) FROM wms.operator_sessions;` |
| A3 | auto | Scan `BADGE-1001` | Menu, greeted as *Marijke Bakker* |
| A4 | manual | Sign in as `BADGE-1003` (Sara, supervisor) | Works the same. **The role is stored but not enforced**: no supervisor-only screens exist |
| A5 | auto | Press "Sign out" | "Signed out.", back to the sign-in screen, cookie cleared |
| A7 | auto | Type `BADGE-1001,BADGE-1002` as the badge | "Badge not recognised." **Signed in as Marijke**: n8n's Postgres node splits parameters on commas and drops the extras, so only `BADGE-1001` was looked up. Scanned values now travel base64-encoded |

## B. Receiving

| # | | Steps | Expected |
|---|---|---|---|
| B1 | auto | Menu → Lines to receive | "Scan the purchase order" |
| B2 | auto | Scan `PO-1042` | "Receiving PO-1042" and the open lines. **Line 1 (Hex bolt) is absent** because it's already fully received |
| B3 | auto | Scan `LOC-A-01-1` at the article step | "Expected an article, but that barcode is location (A-01-1)." It names what you *did* scan |
| B4 | auto | Scan `NOT-A-BARCODE` | "Unknown barcode: NOT-A-BARCODE" |
| B4b | auto | Scan `4000000001007,x` | "Unknown barcode: 4000000001007,x". **Was accepted as `4000000001007`**, for the same reason as A7 |
| B5 | auto | Scan `4000000001002` (Hex nut, not on this order) | "…is not on this order, or is already fully received." |
| B6 | manual | Scan `4000000001001` (Hex bolt, on the order but closed) | Same refusal. Closed lines can't be received |
| B7 | auto | Scan `4000000001007`, enter `25` | "Received 25 of 200 × Wire ferrule 1.5mm. Put-away task created." |
| B8 | auto | Check B7 in the database | `received_qty = 25`; one ledger row; 25 on `DOCK-IN`; one open `putaway_tasks` row |
| B9 | auto | Receive a whole line (`4000000001011`, qty `48`) | Line closes and leaves the open-lines list |

### B10–B14: quantity validation

These two found real bugs during the evaluation, both since fixed. They're the cases most likely to regress.

| # | | Enter at the quantity step | Expected |
|---|---|---|---|
| B10–12 | auto | `0`, `-5`, `abc` | "Enter a whole quantity greater than zero." |
| B13 | auto | `3.7` | Same refusal. **Was a blank screen with no message at all**: it passed the JavaScript check, then failed in the SQL call |
| B14 | auto | `999` on a line with 200 open | "Only 200 still open on this line. Enter 200 or less." **Was accepted**, booking 999 into stock and leaving `received_qty > ordered_qty` for good |

After B10–B14, `received_qty` on that line must still be `0`. Nothing was partly applied.

## C. Put-away and stock counts

| # | | Steps | Expected |
|---|---|---|---|
| C1 | auto | Receive anything (B7) | A put-away task is created automatically, from `DOCK-IN`, with a suggested destination |
| C2 | manual | Complete it via SQL (there is no put-away screen, see *Not built*): `SELECT * FROM wms.complete_putaway(1, (SELECT id FROM wms.locations WHERE code = 'B-02-1'), 1);` | Stock leaves `DOCK-IN` and lands in the bin; two ledger rows (`putaway_out`, `putaway_in`); the ledger query in G still returns zero |
| C3 | auto | 20 simultaneous `wms.adjust_stock()` counts of 5 on one bin (there is no count screen, see *Not built*) | 5 on the shelf, one ledger row. **Was 30 on the shelf and two errors**: the function read the balance without locking it, so every count saw 0 and added 5 |

## D. Picking

| # | | Steps | Expected |
|---|---|---|---|
| D1 | auto | Menu → Picks waiting | The first task in walking order: "Pick 20 × Hex nut M8 from A-01-2." |
| D2 | auto | Scan `LOC-B-01-2` (wrong shelf) | "Wrong shelf. Go to A-01-2." |
| D3 | auto | Scan `LOC-A-01-2` | Accepted → "Scan the article" |
| D4 | auto | Scan `4000000001006` (wrong article) | "Wrong article. This task wants Hex nut M8." The check is by SKU: it used to compare product names, which aren't unique |
| D5–6 | auto | Scan `4000000001002`, enter `20` | "Picked 20 × Hex nut M8." Task `done`; `A-01-2` goes 120 → 100, exactly once |
| D7 | auto | Task 3 (DIN rail): 10 requested, 8 on the shelf. Enter `8` | "Short pick recorded: 8 of 10 × DIN rail 35mm. 2 still owed." Task status `short`, not `done`. Not rounded, not retried |
| D8 | auto | Task 3, enter `10` when only 8 are there | "The system shows only 8 at C-01-1. Enter 8 or less and report the difference." The task stays open. **Was a bare HTTP 500**: stock was protected by the `qty >= 0` check, but the operator got no message |

### D9–D12: quantity validation

The picking counterpart of B10–B14. Both were found in a later audit: picking had never been given the checks receiving already had.

| # | | Enter at the quantity step | Expected |
|---|---|---|---|
| D9–11 | auto | `-1`, `abc`, `2.5` | "Enter how many you picked (0 if none)." **`2.5` was a bare HTTP 500**, the same bug B13 fixed for receiving |
| D12 | auto | `25` on a task for 20 | "This task is for 20. Enter 20 or less." **Was accepted**, closing the task with `picked_qty > qty` and over-picking the order line. `wms.confirm_pick()` now refuses it on its own too |

## E. Two operators

| # | | Steps | Expected |
|---|---|---|---|
| E1–3 | auto | `BADGE-1001` and `BADGE-1002` both press "Picks waiting" | Different tasks. `claim_next_pick()` uses `FOR UPDATE SKIP LOCKED`, so no task is handed to two people |
| E4 | auto | Both finish their tasks | Order stays `picking` while the short pick leaves 2 owed |

## F. Recovery: the part that matters most

| # | | Steps | Expected |
|---|---|---|---|
| F1 | auto | Mid-receive (after scanning the article), **reload** | Same step, same article, nothing lost |
| F2 | auto | Mid-task, sign in on a second device with the same badge | The task continues there at the same step: "the handheld died, grab another one" |
| F3 | manual | Reload repeatedly on any screen after a scan | No second booking. Every scan is POST → 303 → GET, so a reload only ever repeats a read |
| F4 | manual | Press the browser **back** button mid-flow | The server's state wins. The next scan is judged against where the session actually is |

## G. Data integrity

Every one of these must hold at all times. Each must return **zero rows**.

```sql
-- The ledger explains every on-hand number.
SELECT p.sku, l.code, i.qty AS on_hand, COALESCE(SUM(t.delta), 0) AS ledger
  FROM wms.inventory i
  JOIN wms.products p  ON p.id = i.product_id
  JOIN wms.locations l ON l.id = i.location_id
  LEFT JOIN wms.inventory_transactions t
         ON t.product_id = i.product_id AND t.location_id = i.location_id
 GROUP BY p.sku, l.code, i.qty
HAVING i.qty <> COALESCE(SUM(t.delta), 0);

-- Nothing is ever negative.
SELECT * FROM wms.inventory WHERE qty < 0;

-- No line is over-received.
SELECT * FROM wms.purchase_order_lines WHERE received_qty > ordered_qty;

-- No task is over-picked.
SELECT * FROM wms.pick_tasks WHERE picked_qty > qty;
```

**G5: the concurrency proof.** The strongest single test here, and the justification for putting every mutation in a `plpgsql` function:

```bash
bench/bench.py contention --workers 10 --per-worker 40
```

400 receipts of the *same* article on the *same* order line, through the full HTTP path, from 10 operators scanning at the same time. It must end with `on_hand = ledger_rows = ledger_sum = received_qty = 400`. It resets the database afterwards.

## H. Performance

```bash
bench/bench.py screen    --levels 1,5,10          # single screen latency
bench/bench.py operators --levels 5,10,25 --think 5 --duration 30
```

See [BENCHMARK.md](BENCHMARK.md) for what to expect and how to read it. **H3 (manual):** time a real scan by hand. It should feel instant; if it doesn't, something is wrong that the benchmark isn't seeing.

## I. Human judgement: what automation can't test

> **Read this before trusting a green suite.** An earlier version of the automated suite
> passed while the terminal was *completely unusable in a real browser*, because n8n
> sandboxes webhook HTML and browsers then drop the session cookie on POST. curl
> doesn't enforce CSP, so the suite couldn't see it ([csp-sandbox.md](csp-sandbox.md)).
> A browser-facing system needs a person in a browser.

Ten minutes on an actual phone:

| # | Check |
|---|---|
| I1 | Is the input **focused automatically** on every screen, including after a redirect? |
| I2 | Are the buttons big enough to hit with gloves on? |
| I3 | Type a barcode fast and end with Enter. Does it submit without touching a button? (That's exactly how a keyboard-wedge scanner behaves.) |
| I4 | Tap somewhere neutral, then type. Does focus come back to the input? |
| I5 | Can you read the confirmation message at arm's length, at a glance? |
| I6 | Does anything shift after load, so a fast operator could scan into the wrong state? |
| I7 | Is it obvious at all times *which step you're on* and *what to scan next*? |
| I8 | **DevTools → Network, submit a scan, open the POST.** With the stock compose file you'll see no `Cookie` header on the request and a `t` field in the form data: that's the sandbox at work and the token doing its job. Behind a proxy that strips the CSP header, the `Cookie` header should be there. |
| I9 | Does the "Scan this" value on screen match the barcode you would actually scan? (It used to show `SKU-1004` where the label reads `4000000001004`, which made the demo impossible to drive by hand.) |

---

## J. Complete scenarios

The sections above test *behaviours*. These are whole jobs, done the way an operator would do them. Reset first.

### J1. Close an inbound order

Sign in → Lines to receive → `PO-1042`, then for each line scan the article and enter the quantity:

| Article | Scan | Qty |
|---|---|---|
| Cable tie 200mm | `4000000001004` | `120` |
| Wire ferrule 1.5mm | `4000000001007` | `200` |
| Heat shrink 6mm | `4000000001011` | `48` |
| Junction box IP65 | `4000000001012` | `30` |

Each line disappears as it closes, and the last one finishes the order ("Order complete.").

```sql
SELECT line_number, ordered_qty, received_qty FROM wms.purchase_order_lines ORDER BY line_number;
SELECT count(*) FROM wms.putaway_tasks;   -- 4, one per receipt
```

### J2. Fulfil an outbound order

| # | Go to | Scan location | Scan article | Qty |
|---|---|---|---|---|
| 1 | A-01-2 | `LOC-A-01-2` | `4000000001002` | `20` |
| 2 | B-01-2 | `LOC-B-01-2` | `4000000001006` | `15` |
| 3 | C-01-1 | `LOC-C-01-1` | `4000000001009` | `8` |

```sql
SELECT id, qty, picked_qty, status FROM wms.pick_tasks ORDER BY id;
-- 1 done (20), 2 done (15), 3 short (8): not done, not quietly 10
```

The shortfall is reported, not rounded away. That's the difference between a system you can trust and a spreadsheet.

### J3. Watch stock change

Stock lookup → `4000000001007`: only `B-02-1`. Receive 25 of it, then look it up again: `DOCK-IN` now appears as well. The dock is a real location, so goods are never in limbo between arriving and being put away.

### J4. Shift handover

`BADGE-1001` gets as far as the quantity step and signs out. `BADGE-1002` signs in and gets his own session. Sign back in as `BADGE-1001` and Marijke's half-finished task is exactly where she left it.

### J5. A full day in one run

J1 → J2 → J3 without stopping, then the ledger query from G. It must still return zero rows.

---

## K. The 10-minute demo script

Reset first. Use a phone if you can.

| # | Do | Say |
|---|---|---|
| 1 | Show the sign-in screen on a phone | "This runs on any handheld with a browser. Nothing to install." |
| 2 | Sign in as Marijke | "Operators sign in with their badge. No passwords on the floor." |
| 3 | Lines to receive → `PO-1042` | "Scan the delivery paperwork. It knows what's still open." |
| 4 | `4000000001007`, qty `25` | **Pause.** "That committed in about a tenth of a second: the ledger row, the stock move and the put-away task, in one database call, so they can't disagree." |
| 5 | **Reload the page** | "Mid-task. Nothing lost. The state is in PostgreSQL, not the browser." |
| 6 | Open the URL on a second device and sign in as Marijke | "Handheld dies, grab another, carry on." |
| 7 | Picks waiting → work through to task 3, enter `8` | "Only eight on the shelf. It records a short pick instead of pretending." |
| 8 | Stock lookup `4000000001009` | "And the stock is consistent everywhere, instantly." |

**Close honestly:** "It handles about 25 to 35 simultaneous operators before it slows down, which covers a site this size. It doesn't do packing, labels or ERP integration."

**If asked "why n8n?":** "Integration. The warehouse logic is ordinary SQL. What n8n buys you is hundreds of connectors when this has to talk to an ERP, a carrier and a marketplace, which is where these projects normally fail."

---

## Not built (don't test these)

- **Put-away completion screen**: `wms.complete_putaway()` exists; there's no screen for it
- **Packing and shipping labels**: no printer work at all
- **Cycle counts and stock adjustment screens**: `wms.adjust_stock()` exists, no screen
- **ERP, carrier or shop integration**: none
- **Offline mode**: every scan needs the server
- **Real scanner hardware**: only tested with keyboard input, which is how a keyboard-wedge scanner behaves, but not proven on a physical device
- **Role enforcement**: `supervisor` is stored, never checked
- **Multi-warehouse**: the schema supports it, the screens assume one
