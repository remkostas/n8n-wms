#!/usr/bin/env bash
# Acceptance test: drives the terminal over HTTP exactly as a handheld browser
# would (form POST -> 303 -> GET), and after every mutation checks that the
# database agrees with what the operator was shown. Nothing is mocked.
#
# It resets the wms schema first (scripts/reset-db.sh), so it is repeatable and
# DESTRUCTIVE: don't run it while somebody is using the terminal.
#
# One honest limit, learned the hard way: curl does not enforce CSP. An earlier
# version of this suite passed in full while the terminal was unusable in a real
# browser (docs/csp-sandbox.md). The "sandboxed browser" section below simulates
# the browser's behaviour by dropping cookies, but only a real browser proves it.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"

"$REPO_ROOT/scripts/reset-db.sh" >/dev/null

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------- HTTP helpers
#
# Each "device" is a cookie jar. PAGE holds the last screen that device saw;
# TOKEN the session token from the last redirect (only used in no-cookie mode).

PAGE=""
TOKEN=""

# open DEVICE -- GET the terminal, as a browser landing on it does.
open_terminal() {
  PAGE="$(curl -sS -b "$TMP/$1" -c "$TMP/$1" "$TERMINAL_URL")"
}

# scan DEVICE ACTION [CODE] -- submit the one form every screen has, then
# follow the 303 like a browser. DEVICE "nocookie" sends no cookies at all and
# carries the session in the hidden `t` field instead, the way a browser behaves
# inside n8n's CSP sandbox.
scan() {
  local dev="$1" action="$2" code="${3:-}" loc
  local jar=(-b "$TMP/$dev" -c "$TMP/$dev")
  local tok=()
  if [ "$dev" = nocookie ]; then jar=(); tok=(--data-urlencode "t=$TOKEN"); fi
  loc="$(curl -sS "${jar[@]}" -o /dev/null -w '%{redirect_url}' -X POST "$TERMINAL_URL/scan" \
         --data-urlencode "action=$action" --data-urlencode "code=$code" "${tok[@]}")"
  if [ -z "$loc" ]; then PAGE="(no redirect)"; return; fi
  TOKEN="$(printf '%s' "$loc" | sed -n 's/.*[?&]t=\([^&]*\).*/\1/p')"
  PAGE="$(curl -sS "${jar[@]}" "$loc")"
}

# The page is HTML-escaped; compare against the escaped form of what the
# operator reads.
html() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e "s/'/\&#39;/g" -e 's/"/\&quot;/g'; }

see()     { if grep -qF -- "$(html "$1")" <<<"$PAGE"; then ok "$2"; else fail "$2 (expected to see: $1)"; fi; }
not_see() { if grep -qF -- "$(html "$1")" <<<"$PAGE"; then fail "$2 (should not see: $1)"; else ok "$2"; fi; }
# The SQL backstops, called directly: the terminal's own checks fire first, so
# driving the UI alone would never prove the database refuses on its own.
refused() { if wms_psql -c "$1" >/dev/null 2>&1; then fail "$2 (was accepted)"; else ok "$2"; fi; }
db()      { local got; got="$(wms_sql "$1")"; if [ "$got" = "$2" ]; then ok "$3"; else fail "$3 (db: expected $2, got $got)"; fi; }

# ---------------------------------------------------------------- A. sessions

section "A. Sign-in and sessions"
open_terminal m
see "Quick demo sign-in" "A1 no session shows the badge screen"

scan m login BADGE-9999
see "Badge not recognised." "A2 unknown badge is refused"
db "SELECT count(*) FROM wms.operator_sessions" 0 "A2 ...and creates no session"

# n8n's Postgres node splits parameters on commas and drops the extras, so
# before the scan was base64-encoded this signed in as BADGE-1001.
scan m login "BADGE-1001,BADGE-1002"
see "Badge not recognised." "A7 a badge with a comma is looked up whole"

scan m login BADGE-1001
see "Signed in as Marijke Bakker" "A3 known badge signs in"
see "Lines to receive" "A3 lands on the menu"
db "SELECT count(*) FROM wms.operator_sessions" 1 "A3 one session row"

PAGE="$(curl -sS -H 'Cookie: other_app=%E0%A4%A' "$TERMINAL_URL")"
see "Quick demo sign-in" "A6 a malformed cookie from another app doesn't break the terminal"

# ---------------------------------------------------------------- B. receiving

section "B. Receiving"
scan m start_receive
see "Scan the purchase order" "B1 receive asks for the order"

scan m receive_po PO-1042
see "Receiving PO-1042" "B2 order accepted"
see "4000000001007" "B2 open lines listed with their barcodes"
not_see "Hex bolt M8x40" "B2 fully received line 1 is not offered"

scan m receive_item LOC-A-01-1
see "Expected an article, but that barcode is location (A-01-1)." "B3 wrong kind of barcode is named"

scan m receive_item NOT-A-BARCODE
see "Unknown barcode: NOT-A-BARCODE" "B4 unknown barcode"

scan m receive_item "4000000001007,x"
see "Unknown barcode: 4000000001007,x" "B4b a barcode with a comma is looked up whole, not truncated"

scan m receive_item 4000000001002
see "is not on this order, or is already fully received." "B5 article not on the order"

scan m receive_item 4000000001007
see "Still expected" "B7 article accepted, quantity screen"

for bad in 0 -5 abc 3.7; do
  scan m receive_qty "$bad"
  see "Enter a whole quantity greater than zero." "B10-13 quantity '$bad' refused"
done
scan m receive_qty 999
see "Only 200 still open on this line. Enter 200 or less." "B14 over-receipt refused"
db "SELECT received_qty FROM wms.purchase_order_lines WHERE id = 3" 0 "B14 ...nothing partially applied"
refused "SELECT * FROM wms.receive_line(3, 201, 1)" "B14 receive_line() refuses it on its own too"

scan m receive_qty 25
see "Received 25 of 200 × Wire ferrule 1.5mm. Put-away task created." "B7 receipt booked"
db "SELECT received_qty FROM wms.purchase_order_lines WHERE id = 3" 25 "B8 PO line updated"
db "SELECT qty FROM wms.stock_on_hand WHERE sku = 'SKU-1007' AND location_code = 'DOCK-IN'" 25 "B8 stock is on the receiving dock"
db "SELECT count(*) FROM wms.inventory_transactions WHERE reason = 'receipt'" 1 "B8 one ledger row"
db "SELECT qty FROM wms.putaway_tasks WHERE status = 'open'" 25 "B8 put-away task created"

open_terminal m
see "Scan the article" "F1 refresh mid-task loses nothing"

scan m receive_item 4000000001011
scan m receive_qty 48
see "Received 48 of 48 × Heat shrink 6mm." "B9 line received in full"
not_see "4000000001011" "B9 closed line leaves the list"

scan m cancel
see "Lines to receive" "B finish order returns to the menu"

# ---------------------------------------------------------------- D. picking

section "D. Picking"
scan m start_pick
see "Pick 20 × Hex nut M8 from A-01-2." "D1 first task in walking order"

scan m pick_location LOC-B-01-2
see "Wrong shelf. Go to A-01-2." "D2 wrong shelf refused"
scan m pick_location LOC-A-01-2
see "Scan the article" "D3 right shelf accepted"
scan m pick_item 4000000001006
see "Wrong article. This task wants Hex nut M8." "D4 wrong article refused"
scan m pick_item 4000000001002
see "Quantity picked" "D5 right article accepted"
for bad in -1 abc 2.5; do
  scan m pick_qty "$bad"
  see "Enter how many you picked (0 if none)." "D9-11 quantity '$bad' refused"
done
scan m pick_qty 25
see "This task is for 20. Enter 20 or less." "D12 over-pick refused"
db "SELECT picked_qty FROM wms.sales_order_lines WHERE id = 1" 0 "D12 ...nothing partially applied"
refused "SELECT * FROM wms.confirm_pick(1, 21, 1)" "D12 confirm_pick() refuses it on its own too"

scan m pick_qty 20
see "Picked 20 × Hex nut M8." "D6 pick confirmed"
db "SELECT qty FROM wms.stock_on_hand WHERE sku = 'SKU-1002'" 100 "D6 shelf stock reduced once"
db "SELECT status FROM wms.pick_tasks WHERE id = 1" "done" "D6 task done"
db "SELECT status FROM wms.sales_orders WHERE order_number = 'SO-2075'" picking "D6 order in progress"

section "E. Two operators"
open_terminal t
scan t login BADGE-1002
see "Signed in as Tom de Vries" "E1 second operator signs in"
scan t start_pick
see "from B-01-2." "E2 Tom is given the next task"
scan m start_pick
see "from C-01-1." "E3 Marijke is given a different one"
db "SELECT count(DISTINCT assigned_user_id) FROM wms.pick_tasks WHERE status = 'in_progress'" 2 "E3 no task is shared"

scan m pick_location LOC-C-01-1
scan m pick_item 4000000001009
scan m pick_qty 10
see "The system shows only 8 at C-01-1. Enter 8 or less and report the difference." "D8 more than on the shelf is refused with a message"
db "SELECT status FROM wms.pick_tasks WHERE id = 3" in_progress "D8 ...and the task stays open"
scan m pick_qty 8
see "Short pick recorded: 8 of 10 × DIN rail 35mm. 2 still owed." "D7 short pick recorded honestly"
db "SELECT status FROM wms.pick_tasks WHERE id = 3" short "D7 task marked short"

scan t pick_location LOC-B-01-2
scan t pick_item 4000000001006
scan t pick_qty 15
see "Picked 15 × Insulation tape 19mm." "E4 Tom finishes his task"
db "SELECT status FROM wms.sales_orders WHERE order_number = 'SO-2075'" picking "E4 order stays open while 2 are still owed"

# ---------------------------------------------------------------- lookup

section "G. Stock lookup"
scan m start_lookup
scan m lookup_item 4000000001007
see "DOCK-IN" "G1 lookup shows stock on the dock"
see "B-02-1" "G1 ...and on the shelf"

# ---------------------------------------------------------------- recovery

section "F. Recovery"
scan m cancel
scan m start_receive
open_terminal m2
scan m2 login BADGE-1001
see "Scan the purchase order" "F2 sign in on another device resumes the same task"

scan m logout
see "Signed out." "A5 sign out"
open_terminal m
see "Quick demo sign-in" "A5 cookie is cleared"

# ---------------------------------------------------------------- CSP sandbox

section "H. Sandboxed browser (no cookies, token in URL and form)"
scan nocookie login BADGE-1003
see "Signed in as Sara Yilmaz" "H1 login without a cookie jar"
if [ -n "$TOKEN" ]; then ok "H1 session token carried in the redirect"; else fail "H1 no token in redirect"; fi
scan nocookie start_lookup
see "Scan an article" "H2 next POST keeps the session via the form field"
TOKEN=""
scan nocookie start_receive
see "Session expired. Scan your badge again." "H3 no cookie and no token means no session"

# ---------------------------------------------------------------- counting

section "C. Concurrent stock counts (no screen yet: wms.adjust_stock() directly)"
# A count sets an absolute quantity. Unlocked, twenty counts of 5 at once all
# read 0 and all added 5, leaving 30 on the shelf.
for _ in $(seq 1 20); do
  wms_psql -c "SELECT * FROM wms.adjust_stock(12, 13, 5, 3)" >/dev/null &
done
wait
db "SELECT qty FROM wms.inventory WHERE product_id = 12 AND location_id = 13" 5 "C3 twenty simultaneous counts of 5 leave 5"
db "SELECT count(*) FROM wms.inventory_transactions WHERE product_id = 12 AND location_id = 13" 1 "C3 ...with one ledger row"

# ---------------------------------------------------------------- invariant

section "Ledger"
db "SELECT count(*) FROM (
      SELECT i.product_id, i.location_id FROM wms.inventory i
      LEFT JOIN (SELECT product_id, location_id, sum(delta) AS s
                   FROM wms.inventory_transactions GROUP BY 1, 2) t
             USING (product_id, location_id)
      WHERE i.qty <> COALESCE(t.s, 0)) x" 0 "ledger sum equals on-hand everywhere"
db "SELECT count(*) FROM wms.pick_tasks WHERE picked_qty > qty" 0 "no task is over-picked"
db "SELECT count(*) FROM wms.sales_order_lines WHERE picked_qty > ordered_qty" 0 "no order line is over-picked"
db "SELECT count(*) FROM wms.purchase_order_lines WHERE received_qty > ordered_qty" 0 "no order line is over-received"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
