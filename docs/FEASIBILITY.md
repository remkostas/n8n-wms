# Can n8n be a warehouse management system?

The question I set out to answer: can a self-hosted WMS be built with n8n as the workflow engine, business-logic layer and HTML server, with PostgreSQL as the only system of record, driven by handheld barcode scanners? And if it can, is that worth selling?

I answered it by building one and measuring it, not by reading documentation. Evaluated in July 2026 on n8n 2.31.6 and re-verified on 2.40.7.

---

## Verdict

**Technically, yes, by a wider margin than I expected.** A barcode terminal served entirely from n8n webhooks over PostgreSQL is fast enough (about 130 ms per scan, end to end), correct under concurrent contention, and recoverable across page refreshes and devices.

**Commercially, no, for two separate reasons.** n8n's licence forbids distributing it as part of a product. And the pitch I started from, "customisable without traditional software development", is contradicted by the code: about 60 % of the logic ended up in SQL.

**Stop as a product. Keep it as a reference implementation and a consulting asset.**

---

## 1. What was built

A working system, driven end to end over HTTP exactly as a handheld browser would drive it.

| | |
|---|---|
| **Schema** | 15 tables and 2 views in `wms`: products, warehouses, locations, inventory, inventory_transactions, purchase orders and lines, sales orders and lines, pick_tasks, putaway_tasks, users, barcode_mappings, operator_sessions, scan_events ([`db/01-schema.sql`](../db/01-schema.sql)) |
| **Business logic** | 13 `plpgsql` functions: `receive_line`, `confirm_pick`, `claim_next_pick`, `complete_putaway`, `apply_movement`, `adjust_stock`, `suggest_putaway_location`, `resolve_barcode`, `screen_data`, `find_receipt_line`, `session_start`, `session_set_state`, `session_touch` ([`db/02-functions.sql`](../db/02-functions.sql)) |
| **n8n workflows** | `WMS: Operator Terminal` (5 nodes) and `WMS: Scan Handler` (17 nodes) |
| **State machine** | login → menu → `receiving_await_po` → `receiving_await_item` → `receiving_await_qty`; `picking_await_location` → `picking_await_item` → `picking_await_qty`; `lookup` |
| **Working flows** | Sign-in and sessions, receiving, put-away task generation, picking including short picks, stock lookup, sign-out |
| **Acceptance test** | [`tests/walkthrough.sh`](../tests/walkthrough.sh): 69 checks, self-resetting, asserting on what the operator sees *and* on what landed in PostgreSQL. Plus 40 unit tests of the Code-node logic ([`tests/unit/`](../tests/unit/)), and CI running both on every push |

Nothing is mocked.

---

## 2. Performance is not the problem, but it's tighter than I first measured

Detail in [BENCHMARK.md](BENCHMARK.md). The evaluation measured the architecture with small probe workflows:

- **About 36 ms per request**, of which n8n's fixed per-execution overhead was about 28 ms. Rendering HTML cost 4 ms, the database query 2 ms.
- **p95 under 200 ms up to about 85 operators.**

Measuring the finished terminal later gave slower numbers, because a real scan is two executions and 16 node runs rather than one small probe:

- **About 130 ms per scan** (POST plus the next screen) at 5–25 operators.
- **A practical ceiling of about 25–35 operators**; p95 passes 1.5 s at 50. An SME warehouse runs 5–30, so it fits, with little headroom.
- **No errors at any load level** in either measurement. n8n queues instead of dropping requests, so overload shows up as slowness, not failures.

The ceiling comes from n8n running every execution in one process. Raising it means queue mode with several workers, which is a noticeably harder thing for a customer to run themselves.

---

## 3. The atomicity constraint, and what it cost

**n8n cannot hold a database transaction across nodes.** Each Postgres node runs its own statement on its own connection. Every warehouse movement is at least two writes, a ledger row and an on-hand change, and those two must never disagree.

The only way out is to make each mutation a single database call. Every mutating operation here is a `plpgsql` function, with `SELECT … FOR UPDATE` where operators could collide.

**It works and it is cheap:** about 3 ms on top of the read-only path. Under maximum contention, 400 concurrent receipts of the *same* article from a zero baseline produce `on_hand = 400, ledger_rows = 400, ledger_sum = 400`, with no lost updates. The acceptance test re-checks that invariant after every run.

This is the most important structural finding, because it decides where the code has to live. That is the subject of the next section.

---

## 4. Maintainability: where the real problem is

Measured at the end of the evaluation, and again on this repo:

| | at evaluation | this repo (code only, no comments or blank lines) |
|---|---:|---:|
| SQL (schema, functions, seed) | **967 lines** | **717 lines** |
| JavaScript inside n8n Code nodes | **624 lines** | **555 lines** |
| SQL share | **61 %** | **56 %** |
| Functional n8n nodes, both workflows | **22** | **22** |
| Of those, nodes doing *business logic* | **about 0** | **about 0** |

(The JavaScript share rose after the evaluation because the session token now also travels in URLs and form fields; see §4d.)

The 22 nodes are two webhooks, a Switch, eight Postgres calls, seven Code nodes, three responders and a no-op. The Postgres nodes call functions; the Code nodes parse requests, decide transitions and render HTML. **No business rule lives in an n8n node.** n8n does routing and transport. PostgreSQL runs the warehouse.

### a) One screen function, and what it says about n8n

One `screen_data(token)` function returns everything any screen needs, so adding a screen means adding a SQL branch and a render branch, not another set of fetch nodes. My first attempt used a Switch fanning out to one Postgres node per screen; collapsing that into SQL is why the terminal workflow has 5 nodes instead of about 20. It was the right call, but it means the growth path leads *out* of n8n.

### b) Version control is poor

Workflows are JSON documents stored in a database, and n8n's git integration is an Enterprise feature. This project has reviewable history only because the Code-node bodies live as files in [`src/terminal/`](../src/terminal/) and [`scripts/build_workflows.py`](../scripts/build_workflows.py) injects them into the workflow JSON. That is a workaround. For anyone shipping per-customer customisations it is a real problem without a cheap answer.

### c) There is no session or CSRF primitive

Cookies, tokens, expiry and state recovery are all hand-written in Code nodes. They work: the test suite covers surviving a refresh and moving to another device mid-task. But it is security-sensitive code that someone has to own for good.

### d) Cookie sessions do not work in a browser by default

The most important finding in this document, and I found it last, by opening the page in a normal browser.

n8n serves every webhook HTML response with `Content-Security-Policy: sandbox …` and deliberately leaves out `allow-same-origin`. That puts the page in an opaque origin, and the browser then refuses to send the session cookie on the form POST. Every scan arrived without a session, while the GET still carried the cookie, so the screen looked healthy until you pressed anything.

The full story and the three possible fixes are in [csp-sandbox.md](csp-sandbox.md). In short, a production deployment has to either weaken a documented n8n security control or carry the session token in the URL and form fields. This repo does the second. **"n8n as a UI server" is not a supported use case.** n8n actively sandboxes against it, and every stateful application built this way works around that.

**A lesson about testing, not the product:** the automated suite passed the whole time the terminal was unusable in a browser, because **curl does not enforce CSP**. A browser-facing system needs at least one real browser in its test loop.

### What this does to the product idea

The pitch was "a workflow-first, self-hosted WMS built on n8n that can be customised without traditional software development".

**The build falsifies it.** Customising this system means writing `plpgsql` and HTML inside JavaScript strings. An honest description of what I built is *a PostgreSQL application with an n8n-shaped HTTP layer*. That's a perfectly good thing, just not what the pitch was selling, and a buyer would notice on their first change request.

---

## 5. Commercial position

In short: the licence rules out shipping it as a product, a services model on the customer's own n8n instance is permitted, and ERPNext already covers the general-purpose WMS space for free. Detail in [COMMERCIAL.md](COMMERCIAL.md).

---

## 6. Recommendation

**Don't build a software product.** Any one of these reasons is enough:

1. **The licence rules out the product shape.** n8n can't be distributed commercially. What remains is services, which is a different business.
2. **The differentiator doesn't survive the build.** Customisation here means SQL and hand-written HTML.
3. **The competitive gap is too big to close alone.** ERPNext offers more, for free, today, with a community behind it.

**The work is still worth having**, just not as a WMS:

- **It answers the underlying question.** Can n8n serve real, stateful, transactional UI at production speed? Yes: about 130 ms a scan, correct under contention, recoverable across sessions. That result carries over to any internal tool worth building this way.
- **The patterns are reusable:** one fetch per screen via `screen_data`, a session and state-machine table, every mutation as one `plpgsql` call, and Code-node source kept in files and pushed by a build script.
- **It reached a negative commercial conclusion from evidence**, including two load-generator bugs caught and corrected along the way.

---

## Not built

Documented and not attempted: packing and shipping labels, cycle-count and stock-adjustment screens (`wms.adjust_stock()` exists, with no UI), the put-away *completion* screen (`wms.complete_putaway()` exists, with no UI), ERP and carrier integration, offline mode, role enforcement, and validation on physical scanner hardware.
