// Unit tests for the n8n Code-node bodies in src/terminal/. No n8n, no
// database, no dependencies: `node --test tests/unit`.
//
// A Code node body is a script that reads other nodes through $() and $input
// and ends in a top-level `return`. Wrapping it in a Function with those two
// names as parameters runs it exactly as n8n would, against fixture data.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SRC = path.join(__dirname, '..', '..', 'src', 'terminal');

// nodes: { 'Node Name': json } for $('Node Name').first().json
// input: json for $input.first().json
function run(files, nodes, input) {
  const code = [].concat(files)
    .map((f) => fs.readFileSync(path.join(SRC, f), 'utf8')).join('\n');
  const $ = (name) => {
    if (!(name in nodes)) throw new Error('unexpected node reference: ' + name);
    return { first: () => ({ json: nodes[name] }) };
  };
  const $input = { first: () => ({ json: input }) };
  return new Function('$', '$input', 'Buffer', code)($, $input, Buffer)[0].json;
}

const ctxPatch = (o) => JSON.parse(Buffer.from(o.ctx_patch_b64, 'base64').toString('utf8'));

// ------------------------------------------------------------ decide_transition

function decide({ state = 'idle', context = {}, payload = {}, action, code, scan = {} }) {
  return run('decide_transition.js', {
    'Load Session': { state, context, payload },
    'Scan Submit': { body: { action, code } },
  }, scan);
}

const PICK_QTY = {
  state: 'picking_await_qty',
  context: { task_id: 3 },
  payload: { qty: 10, on_hand: 8, location_code: 'C-01-1' },
  action: 'pick_qty',
};

const unb64 = (v) => Buffer.from(v, 'base64').toString('utf8');

test('login with a badge asks for a session, badge intact through the comma split', () => {
  const o = decide({ state: 'login', action: 'login', code: ' BADGE-1001,BADGE-1002 ' });
  assert.equal(o.op, 'login');
  assert.doesNotMatch(o.badge_b64, /,/);
  assert.equal(unb64(o.badge_b64), 'BADGE-1001,BADGE-1002');
});

test('any other action without a session is sent back to the badge screen', () => {
  const o = decide({ state: 'login', action: 'start_receive' });
  assert.equal(o.op, 'none');
  assert.equal(o.next_state, 'login');
  assert.match(o.msg, /Session expired/);
});

test('sign-out clears the cookie', () => {
  assert.equal(decide({ action: 'logout' }).clear_cookie, true);
});

test('a scan of the wrong kind of thing names what was scanned, with the right article', () => {
  const loc = { entity_type: 'location', entity_id: 4, label: 'A-01-1' };
  const o = decide({ state: 'receiving_await_item', action: 'receive_item', code: 'LOC-A-01-1', scan: loc });
  assert.equal(o.msg, 'Expected an article, but that barcode is location (A-01-1).');
  const p = decide({ state: 'receiving_await_po', action: 'receive_po', code: 'LOC-A-01-1', scan: loc });
  assert.equal(p.msg, 'Expected a purchase order, but that barcode is location (A-01-1).');
});

test('an unknown barcode resolves to an empty item, not a match', () => {
  // alwaysOutputData turns "no rows" into {}, which must not read as a hit.
  const o = decide({ state: 'receiving_await_po', action: 'receive_po', code: 'NOPE', scan: {} });
  assert.equal(o.msg, 'Unknown barcode: NOPE');
});

test('receiving an article matches it to its open line', () => {
  const o = decide({
    state: 'receiving_await_item', context: { po_id: 1 },
    payload: { lines: [{ po_line_id: 3, product_id: 7, open_qty: 200 }] },
    action: 'receive_item', code: '4000000001007',
    scan: { entity_type: 'product', entity_id: '7', label: 'Wire ferrule 1.5mm' },
  });
  assert.equal(o.next_state, 'receiving_await_qty');
  assert.deepEqual(ctxPatch(o), { po_line_id: 3, open_qty: 200 });
});

for (const bad of ['', '0', '-5', 'abc', '3.7']) {
  test(`receive quantity '${bad}' is refused`, () => {
    const o = decide({ state: 'receiving_await_qty', context: { po_line_id: 3, open_qty: 200 },
                       action: 'receive_qty', code: bad });
    assert.equal(o.op, 'none');
    assert.equal(o.msg, 'Enter a whole quantity greater than zero.');
  });
}

test('over-receipt is refused', () => {
  const o = decide({ state: 'receiving_await_qty', context: { po_line_id: 3, open_qty: 200 },
                     action: 'receive_qty', code: '999' });
  assert.equal(o.op, 'none');
  assert.equal(o.msg, 'Only 200 still open on this line. Enter 200 or less.');
});

test('a valid receipt goes to the database', () => {
  const o = decide({ state: 'receiving_await_qty', context: { po_line_id: 3, open_qty: 200 },
                     action: 'receive_qty', code: '25' });
  assert.equal(o.op, 'receive');
  assert.equal(o.po_line_id, 3);
  assert.equal(o.qty, 25);
});

test('the wrong shelf is refused', () => {
  const o = decide({ state: 'picking_await_location', payload: { location_code: 'A-01-2' },
                     action: 'pick_location', code: 'LOC-B-01-2',
                     scan: { entity_type: 'location', entity_id: 9, label: 'B-01-2' } });
  assert.equal(o.msg, 'Wrong shelf. Go to A-01-2.');
});

for (const bad of ['', '-1', 'abc', '2.5']) {
  test(`pick quantity '${bad}' is refused`, () => {
    const o = decide({ ...PICK_QTY, code: bad });
    assert.equal(o.op, 'none');
    assert.equal(o.msg, 'Enter how many you picked (0 if none).');
  });
}

test('picking more than the task asks for is refused', () => {
  const o = decide({ ...PICK_QTY, payload: { ...PICK_QTY.payload, on_hand: 50 }, code: '11' });
  assert.equal(o.op, 'none');
  assert.equal(o.msg, 'This task is for 10. Enter 10 or less.');
});

test('picking more than the system has on the shelf is refused with a message', () => {
  const o = decide({ ...PICK_QTY, code: '9' });
  assert.equal(o.op, 'none');
  assert.equal(o.msg, 'The system shows only 8 at C-01-1. Enter 8 or less and report the difference.');
});

test('the picked article is checked by SKU, not by its (non-unique) name', () => {
  const at = { state: 'picking_await_item', payload: { sku: 'SKU-1004', product_name: 'Cable tie' },
               action: 'pick_item', code: '4000000009999' };
  const twin = decide({ ...at, scan: { entity_type: 'product', entity_id: 99, label: 'Cable tie', detail: 'SKU-9999' } });
  assert.equal(twin.msg, 'Wrong article. This task wants Cable tie.');
  const right = decide({ ...at, scan: { entity_type: 'product', entity_id: 4, label: 'Cable tie', detail: 'SKU-1004' } });
  assert.equal(right.next_state, 'picking_await_qty');
});

test('a short pick goes to the database', () => {
  const o = decide({ ...PICK_QTY, code: '8' });
  assert.equal(o.op, 'confirm_pick');
  assert.equal(o.qty, 8);
});

test('zero is a legitimate pick: it reports an empty shelf', () => {
  const o = decide({ ...PICK_QTY, payload: { ...PICK_QTY.payload, on_hand: 0 }, code: '0' });
  assert.equal(o.op, 'confirm_pick');
  assert.equal(o.qty, 0);
});

test('cancel steps back one level', () => {
  assert.equal(decide({ state: 'receiving_await_qty', action: 'cancel' }).next_state, 'receiving_await_item');
  assert.equal(decide({ state: 'picking_await_qty', action: 'cancel' }).next_state, 'picking_await_location');
  assert.equal(decide({ state: 'lookup', action: 'cancel' }).next_state, 'idle');
});

test('context patches survive commas (the Postgres node splits on them)', () => {
  const o = decide({ state: 'receiving_await_po', action: 'receive_po', code: 'PO-1042',
                     scan: { entity_type: 'purchase_order', entity_id: '1', label: 'PO-1042' } });
  assert.doesNotMatch(o.ctx_patch_b64, /,/);
  assert.deepEqual(ctxPatch(o), { po_id: 1, po_number: 'PO-1042' });
});

// ------------------------------------------------------------ next_state

function next(decision, result) {
  return run('next_state.js', { 'Decide Transition': decision }, result);
}

test('a short pick is reported as a warning with what is still owed', () => {
  const o = next({ op: 'confirm_pick' }, {
    picked_qty: 8, requested_qty: 10, remaining: 2, product_name: 'DIN rail 35mm', order_complete: false,
  });
  assert.equal(o.kind, 'warn');
  assert.equal(o.msg, 'Short pick recorded: 8 of 10 × DIN rail 35mm. 2 still owed.');
});

test('no pick left to claim returns to the menu', () => {
  const o = next({ op: 'claim_pick' }, {});
  assert.equal(o.next_state, 'idle');
  assert.equal(o.msg, 'No picks waiting.');
});

test('the last receipt on an order finishes it', () => {
  const o = next({ op: 'receive' }, {
    received_qty: 30, ordered_qty: 30, product_name: 'Junction box IP65', po_complete: true,
  });
  assert.equal(o.next_state, 'idle');
  assert.match(o.msg, /Order complete\.$/);
});

// ------------------------------------------------------------ request readers

for (const file of ['terminal_read_request.js', 'scan_read_request.js']) {
  test(`${file}: the cookie wins, and a malformed foreign cookie is survived`, () => {
    const o = run(file, {}, {
      headers: { cookie: 'other=%E0%A4%A; wms_session=abc%3D' },
      query: { t: 'from-url' }, body: { t: 'from-form' },
    });
    assert.equal(o.token, 'abc=');
  });

  test(`${file}: no session gives a non-empty query parameter`, () => {
    const o = run(file, {}, { headers: {}, query: {}, body: {} });
    assert.equal(o.has_session, false);
    assert.equal(o.token_param, '-');
  });
}

test('terminal_read_request.js falls back to the URL token', () => {
  assert.equal(run('terminal_read_request.js', {}, { headers: {}, query: { t: 'tok' } }).token, 'tok');
});

test('scan_read_request.js falls back to the form token', () => {
  assert.equal(run('scan_read_request.js', {}, { headers: {}, body: { t: 'tok' } }).token, 'tok');
});

test('scan_read_request.js passes the scanned code intact through the comma split', () => {
  const o = run('scan_read_request.js', {}, { headers: {}, body: { code: ' PO-1042,x ' } });
  assert.doesNotMatch(o.code_b64, /,/);
  assert.equal(unb64(o.code_b64), 'PO-1042,x');
  // Menu buttons submit no code; the sentinel matches no barcode.
  assert.equal(unb64(run('scan_read_request.js', {}, { headers: {}, body: {} }).code_b64), '-');
});

// ------------------------------------------------------------ redirects

test('redirects are absolute, honour the proxy headers, and carry the token', () => {
  const o = run(['redirect_base.js', 'build_redirect.js'], {
    'Next State': { msg: 'OK', kind: 'ok' },
    'Scan Submit': { headers: { host: 'n8n:5678', 'x-forwarded-host': 'wms.example.com',
                                'x-forwarded-proto': 'https' } },
    'Read Request': { token: 'tok' },
  }, {});
  assert.match(o.location, /^https:\/\/wms\.example\.com\/webhook\/wms\?msg=OK&kind=ok&t=tok&cb=\d+$/);
  assert.equal(o.cookie, undefined);
});

test('sign-out drops the token from the URL and clears the cookie', () => {
  const o = run(['redirect_base.js', 'build_redirect.js'], {
    'Next State': { msg: 'Signed out.', kind: 'info', clear_cookie: true },
    'Scan Submit': { headers: { host: 'localhost:5678' } },
    'Read Request': { token: 'tok' },
  }, {});
  assert.doesNotMatch(o.location, /[?&]t=/);
  assert.match(o.cookie, /Max-Age=0/);
});

test('an unknown badge clears any stale cookie', () => {
  const o = run(['redirect_base.js', 'build_login_redirect.js'], {
    'Scan Submit': { headers: { host: 'localhost:5678' } },
  }, {});
  assert.match(o.location, /msg=Badge%20not%20recognised\./);
  assert.match(o.cookie, /^wms_session=; .*Max-Age=0/);
});

// ------------------------------------------------------------ render_screen

function render(row, query = {}, token = '') {
  return run('render_screen.js', {
    'Terminal Request': { query },
    'Read Request': { token },
  }, row).html;
}

test('every flash message and value is HTML-escaped', () => {
  const html = render({ state: 'idle', user_name: '<b>x</b>', payload: {} },
                      { msg: '<script>alert(1)</script>', kind: 'ok' }, 'tok');
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/);
});

test('an injected flash kind cannot break out of the class attribute', () => {
  const html = render({ state: 'idle', payload: {} }, { msg: 'm', kind: "ok' onmouseover='x" }, 'tok');
  assert.doesNotMatch(html, /' onmouseover='/);
});

test('authenticated forms carry the token; the sign-in screen does not', () => {
  assert.match(render({ state: 'idle', payload: {} }, {}, 'tok'), /name='t' value='tok'/);
  assert.doesNotMatch(render({ state: 'login' }), /name='t'/);
});

test('the sign-in tiles use the full names from the seed data', () => {
  const html = render({ state: 'login' });
  for (const name of ['Marijke Bakker', 'Tom de Vries', 'Sara Yilmaz']) assert.match(html, new RegExp(name));
});
