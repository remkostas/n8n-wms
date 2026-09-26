// Turns a mutation's result into the next screen. Runs in the "Next State"
// Code node of the WMS: Scan Handler workflow, after the Switch branches
// converge.
//
// Only one branch of the Switch ever runs, so this node sees exactly one
// mutation result -- but it cannot tell which one from the data alone, because
// the shapes differ. It reads the decision back from "Decide Transition"
// instead of guessing from the fields present.

const decision = $('Decide Transition').first().json;
const op = decision.op;
const result = $input.first().json || {};

function done(nextState, patch, msg, kind) {
  return [{ json: {
    next_state: nextState,
    // See the note in decide_transition.js: comma-free encoding, because the
    // Postgres node splits its parameter list on commas.
    ctx_patch_b64: Buffer.from(JSON.stringify(patch || {})).toString('base64'),
    msg: msg || '',
    kind: kind || 'info'
  } }];
}

// Nothing was mutated: "Decide Transition" already worked out where to go.
if (op === 'none') {
  return [{ json: {
    next_state: decision.next_state,
    ctx_patch_b64: decision.ctx_patch_b64,
    msg: decision.msg,
    kind: decision.kind,
    clear_cookie: decision.clear_cookie === true
  } }];
}

if (op === 'receive') {
  const complete = result.po_complete === true;
  const msg = 'Received ' + result.received_qty + ' of ' + result.ordered_qty
    + ' × ' + result.product_name + '. Put-away task created.';
  // Clearing po_line_id matters: leaving it set would make the next quantity
  // screen silently re-target the article that was just finished.
  return done(complete ? 'idle' : 'receiving_await_item', { po_line_id: null },
    complete ? msg + ' Order complete.' : msg, 'ok');
}

if (op === 'claim_pick') {
  // A Postgres node with alwaysOutputData emits a synthetic empty item rather
  // than zero items, so "no work left" has to be detected by the absence of the
  // identifying field, not by an empty result set.
  if (!result.task_id) {
    return done('idle', {}, 'No picks waiting.', 'info');
  }
  return done('picking_await_location', { task_id: Number(result.task_id) },
    'Pick ' + result.qty + ' × ' + result.product_name
      + ' from ' + result.location_code + '.', 'info');
}

if (op === 'confirm_pick') {
  const short = Number(result.picked_qty) < Number(result.requested_qty);
  let msg = 'Picked ' + result.picked_qty + ' × ' + result.product_name + '.';
  if (short) {
    msg = 'Short pick recorded: ' + result.picked_qty + ' of ' + result.requested_qty
      + ' × ' + result.product_name + '. ' + result.remaining + ' still owed.';
  }
  if (result.order_complete === true) {
    msg += ' Order ' + result.order_number + ' fully picked.';
  }
  return done('idle', { task_id: null }, msg, short ? 'warn' : 'ok');
}

return done('idle', {}, 'Unknown operation.', 'bad');
