// The state machine. Runs in the "Decide Transition" Code node of the
// WMS: Scan Handler workflow.
//
// This node is deliberately pure: it reads the current session, the scanned
// value and what that value resolved to, and returns a decision. It touches
// nothing. Every write is done by a Postgres node downstream, selected by a
// Switch on `op`.
//
// That split is the point of the experiment. n8n cannot hold a transaction
// across nodes, so the *mutations* had to move into SQL functions -- but the
// *decisions* did not have to follow them, and keeping them here means the
// business rules stay readable, unit-testable, and visible on the canvas
// instead of disappearing into plpgsql. See FEASIBILITY.md.
//
// Input:
//   session  { state, user_id, context, payload }   from wms.screen_data
//   scan     { entity_type, entity_id, label, detail }  from wms.resolve_barcode (may be empty)
//   body     { action, code }                       the submitted form
// Output:
//   { op, next_state, ctx_patch, msg, kind, ...params }
//     op: 'none' | 'login' | 'receive' | 'claim_pick' | 'confirm_pick'

const session = $('Load Session').first().json || {};
const body = $('Scan Submit').first().json.body || {};

// resolve_barcode returns zero rows for an unknown code. alwaysOutputData turns
// that into one empty item rather than no item, so check for the field, not the
// item count -- a synthetic {} would otherwise read as a successful resolution.
const scanRaw = $input.first().json || {};
const scan = scanRaw.entity_type ? scanRaw : null;

const state = session.state || 'login';
const ctx = session.context || {};
const payload = session.payload || {};
const action = String(body.action || '');
const code = String(body.code === undefined ? '' : body.code).trim();

function out(op, nextState, patch, msg, kind, extra) {
  const o = {
    op: op,
    next_state: nextState === undefined || nextState === null ? state : nextState,
    // Base64, not raw JSON. n8n's Postgres node binds query parameters by
    // splitting the queryReplacement string on commas, so any JSON object with
    // more than one key would be shredded into several bogus parameters. Base64
    // has no commas, and the SQL side decodes it back to jsonb.
    ctx_patch_b64: Buffer.from(JSON.stringify(patch || {})).toString('base64'),
    msg: msg || '',
    kind: kind || 'info'
  };
  if (extra) { for (const k in extra) o[k] = extra[k]; }
  return [{ json: o }];
}

// A scan that resolved to the wrong kind of thing is the single most common
// operator error. Say what was scanned rather than just refusing, otherwise the
// operator has no way to tell a mis-scan from a broken system.
function wrongThing(expected) {
  const got = scan ? scan.entity_type.replace('_', ' ') + ' (' + scan.label + ')' : 'nothing known';
  const article = /^[aeiou]/.test(expected) ? 'an ' : 'a ';
  return out('none', state, null,
    'Expected ' + article + expected + ', but that barcode is ' + got + '.', 'warn');
}

// --------------------------------------------------------------- login

if (action === 'login') {
  if (!code) return out('none', 'login', null, 'Scan your badge to continue.', 'warn');
  // Base64 for the same comma-split reason as ctx_patch_b64.
  return out('login', null, null, null, null,
    { badge_b64: Buffer.from(code).toString('base64') });
}

// Any action other than login without a live session means the session expired
// mid-task. Send them back to the badge screen rather than failing the request.
if (state === 'login') {
  return out('none', 'login', null, 'Session expired. Scan your badge again.', 'warn');
}

if (action === 'logout') {
  // The session row is left to expire on its own rather than deleted: an
  // operator who signs out on a shared handheld and back in on their own should
  // find their half-finished task still there.
  const o = out('none', state, null, 'Signed out.', 'info');
  o[0].json.clear_cookie = true;
  return o;
}

// --------------------------------------------------------------- navigation

if (action === 'cancel') {
  // Cancel steps back one level rather than always dumping to the menu: an
  // operator who scanned the wrong article wants the article prompt again, not
  // to restart the whole receipt.
  if (state === 'receiving_await_qty') return out('none', 'receiving_await_item', null, null, null);
  if (state === 'picking_await_qty')   return out('none', 'picking_await_location', null, null, null);
  return out('none', 'idle', {}, null, null);
}

if (action === 'start_receive') return out('none', 'receiving_await_po', {}, null, null);
if (action === 'start_lookup')  return out('none', 'lookup', {}, null, null);
if (action === 'start_pick')    return out('claim_pick', null, null, null, null);

// --------------------------------------------------------------- receiving

if (action === 'receive_po') {
  if (!scan) return out('none', state, null, 'Unknown barcode: ' + code, 'bad');
  if (scan.entity_type !== 'purchase_order') return wrongThing('purchase order');
  return out('none', 'receiving_await_item',
    { po_id: Number(scan.entity_id), po_number: scan.label },
    'Receiving ' + scan.label, 'ok');
}

if (action === 'receive_item') {
  if (!scan) return out('none', state, null, 'Unknown barcode: ' + code, 'bad');
  if (scan.entity_type !== 'product') return wrongThing('article');

  // The open lines for this order were already loaded for the screen, so
  // matching the scanned article to a line is a lookup in memory rather than
  // another database round trip.
  const lines = payload.lines || [];
  let match = null;
  for (const l of lines) {
    if (Number(l.product_id) === Number(scan.entity_id)) { match = l; break; }
  }
  if (!match) {
    return out('none', state, null,
      scan.label + ' is not on this order, or is already fully received.', 'warn');
  }
  // open_qty rides along in the context so the quantity step can bound-check
  // the entry without another round trip.
  return out('none', 'receiving_await_qty',
    { po_line_id: Number(match.po_line_id), open_qty: Number(match.open_qty) }, null, null);
}

if (action === 'receive_qty') {
  const qty = Number(code);
  // Integer, not just positive-and-finite. A decimal passes Number() happily and
  // then dies in the Postgres call, whose parameter is INTEGER -- and that error
  // surfaced to the operator as a blank screen with no message at all, which is
  // the worst possible outcome on a warehouse floor. Reject it here where there
  // is still somewhere to show a message.
  if (!code || !isFinite(qty) || !Number.isInteger(qty) || qty <= 0) {
    return out('none', state, null, 'Enter a whole quantity greater than zero.', 'warn');
  }
  if (!ctx.po_line_id) {
    return out('none', 'receiving_await_item', null, 'Scan the article again.', 'warn');
  }
  // Over-receipt guard. Without it a typo ("999" for "99") silently books
  // twenty times the ordered quantity into stock and the purchase order shows
  // received > ordered forever. Real sites do sometimes accept over-delivery,
  // so this is the place a tolerance would be configured -- but silently
  // accepting any number is not a policy, it is a missing check.
  const open = Number(ctx.open_qty);
  if (isFinite(open) && open > 0 && qty > open) {
    return out('none', state, null,
      'Only ' + open + ' still open on this line. Enter ' + open + ' or less.', 'warn');
  }
  return out('receive', null, null, null, null,
    { po_line_id: Number(ctx.po_line_id), qty: qty });
}

// --------------------------------------------------------------- picking

if (action === 'pick_location') {
  if (!scan) return out('none', state, null, 'Unknown barcode: ' + code, 'bad');
  if (scan.entity_type !== 'location') return wrongThing('location');
  if (scan.label !== payload.location_code) {
    return out('none', state, null,
      'Wrong shelf. Go to ' + payload.location_code + '.', 'warn');
  }
  return out('none', 'picking_await_item', null, null, null);
}

if (action === 'pick_item') {
  if (!scan) return out('none', state, null, 'Unknown barcode: ' + code, 'bad');
  if (scan.entity_type !== 'product') return wrongThing('article');
  // By SKU (resolve_barcode's `detail` for a product), not by name: SKUs are
  // unique, names aren't, so two articles called "Cable tie" would pass for
  // each other.
  if (scan.detail !== payload.sku) {
    return out('none', state, null,
      'Wrong article. This task wants ' + payload.product_name + '.', 'warn');
  }
  return out('none', 'picking_await_qty', null, null, null);
}

if (action === 'pick_qty') {
  const qty = Number(code);
  // Zero is legitimate here and must not be rejected: it is how an operator
  // reports an empty shelf. Refusing it would push them to invent a number.
  // Integer for the same reason as receive_qty: a decimal would die in the
  // Postgres call as a bare 500.
  if (code === '' || !isFinite(qty) || !Number.isInteger(qty) || qty < 0) {
    return out('none', state, null, 'Enter how many you picked (0 if none).', 'warn');
  }
  if (!ctx.task_id) {
    return out('claim_pick', null, null, 'Lost the task, fetching the next one.', 'warn');
  }
  // Over-pick guard, the mirror of the over-receipt guard above: a typo of 25
  // for 20 would otherwise close the task and leave the order line picked
  // beyond what the customer ordered. confirm_pick() refuses it too.
  const requested = Number(payload.qty);
  if (isFinite(requested) && requested > 0 && qty > requested) {
    return out('none', state, null,
      'This task is for ' + requested + '. Enter ' + requested + ' or less.', 'warn');
  }
  // The database refuses to take stock below zero, and before this check that
  // refusal reached the operator as a bare HTTP 500. Saying what the system
  // believes is on the shelf turns it into something they can act on.
  const onHand = Number(payload.on_hand);
  if (isFinite(onHand) && qty > onHand) {
    return out('none', state, null,
      'The system shows only ' + onHand + ' at ' + payload.location_code
        + '. Enter ' + onHand + ' or less and report the difference.', 'warn');
  }
  return out('confirm_pick', null, null, null, null,
    { task_id: Number(ctx.task_id), qty: qty });
}

// --------------------------------------------------------------- lookup

if (action === 'lookup_item') {
  if (!scan) return out('none', 'lookup', { product_id: null }, 'Unknown barcode: ' + code, 'bad');
  if (scan.entity_type !== 'product') return wrongThing('article');
  return out('none', 'lookup', { product_id: Number(scan.entity_id) }, null, null);
}

return out('none', state, null, 'Unrecognised action.', 'bad');
