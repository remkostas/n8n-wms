# CLAUDE.md

Working notes for coding agents (and people) changing this repo. The README says what the project is; this says how not to break it.

## Where things live

- `db/02-functions.sql`: all business logic. Every stock movement is **one** `plpgsql` call, because n8n cannot hold a transaction across nodes. Never split a mutation into several Postgres nodes.
- `src/terminal/*.js`: the bodies of the n8n Code nodes, as plain files. `scripts/build_workflows.py` inlines them into `workflows/*.template.json` (`"@file:a.js+b.js"`). Edit the `.js` files, never a built workflow. `workflows/dist/` is generated and ignored.
- `decide_transition.js` is pure: it decides, a Postgres node downstream writes. Keep it that way; it's what makes it unit-testable.

## Rules that aren't obvious from the code

- **A mutation that reads a quantity and then writes one locks the row first** (`FOR UPDATE`). `adjust_stock()` didn't, and concurrent counts added up instead of agreeing.
- **Invariants belong in SQL as well as in the Code node.** The terminal bound-checks quantities for a friendly message; `receive_line()` and `confirm_pick()` refuse the same thing on their own. Add both sides for any new check.
- **n8n's Postgres node splits `queryReplacement` on commas and silently drops the extras.** Anything that can contain a comma goes in base64-encoded and is decoded in SQL: the context patch (`ctx_patch_b64`), and anything typed or scanned (`code_b64`, `badge_b64`). A raw `PO-1042,x` was looked up as `PO-1042`.
- **Postgres nodes with `alwaysOutputData` emit `{}` for "no rows".** Test for the identifying field, not for an empty result.
- **The terminal must work inside n8n's webhook CSP sandbox**, where browsers send no cookie on form POSTs. Every authenticated form carries the token as a hidden `t` field and every redirect carries it as `?t=`. A new form without `tokenField()` works in curl and fails in a real browser.
- **A decimal or out-of-range quantity that reaches SQL becomes a bare HTTP 500.** Validate in `decide_transition.js` first.
- Everything shown to the operator goes through `esc()`.

## Checks

```bash
node --test tests/unit/*.test.js    # seconds, no stack needed: run after any src/ change
shellcheck -x scripts/*.sh tests/*.sh

cp .env.example .env                # set the two secrets
docker compose up -d && scripts/setup.sh   # re-run setup.sh to deploy src/ changes
tests/walkthrough.sh                # acceptance test; DESTRUCTIVE, resets the wms schema
bench/bench.py contention           # ledger must reconcile exactly; also resets
```

CI (`.github/workflows/ci.yml`) runs all of this on every push. When the number of checks changes, update the counts in `README.md` and `docs/FEASIBILITY.md`; when behaviour changes, update the matching case in `docs/TEST-CASES.md`.

## Tone of the docs

The docs report measured results, including the unflattering ones: the slower real-world benchmark, the bug the test suite missed, the commercial "no". Keep it that way. Don't round numbers up or drop a caveat to make something read better.
