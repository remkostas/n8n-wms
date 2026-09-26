// Renders every operator screen. Runs in the "Render Screen" Code node of the
// WMS: Operator Terminal workflow.
//
// WHY THIS IS ONE NODE AND NOT ONE NODE PER SCREEN
//
// n8n has no include, import or partial mechanism for Code nodes. A workflow
// with a Code node per screen would therefore repeat the page chrome -- doctype,
// CSS, header, focus script -- in every one of them, and they would drift apart
// the first time someone restyled a single screen. The options were: duplicate
// the chrome (drift), call a shared render sub-workflow (a whole extra n8n
// execution per page, ~25 ms on top of the ~34 ms the page already costs), or
// collapse every screen into one node that dispatches internally.
//
// This is the third. It keeps one copy of the chrome and adds no latency, at the
// cost of the workflow canvas telling you nothing about the UI: all five screens
// hide behind a single box labelled "Render Screen". That trade-off is a finding
// in its own right, not an accident -- see FEASIBILITY.md.
//
// Input  (from wms.screen_data): { state, user_name, context, payload }
// Output: { html }

const row = $input.first().json;
const state = row.state || 'login';
const userName = row.user_name || '';
const ctx = row.context || {};
const data = row.payload || {};

// Flash messages survive the POST-redirect-GET hop as query parameters, because
// the alternative -- storing them in the session -- means another write on every
// scan purely to say "OK".
const q = ($('Terminal Request').first().json.query) || {};
const flash = q.msg || '';
const flashKind = q.kind || 'info';

// The session token, threaded into a hidden `t` field on every authenticated
// form below (and read back by Scan Handler's Read Request). Needed because
// n8n's webhook CSP sandbox opaque-origins the page, and opaque origins don't
// reliably attach cookies to a same-page form POST -- only to a fresh
// top-level GET. Behind a proxy that strips the CSP header the cookie carries
// the session by itself; this is what keeps a stock n8n working.
const token = ($('Read Request').first().json.token) || '';

function esc(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

const CSS = [
  ':root{--bg:#10131a;--panel:#1a1f2b;--line:#2c3444;--ink:#eef2f8;--muted:#9aa7bd;',
  '--accent:#3b82f6;--ok:#22c55e;--warn:#f59e0b;--bad:#ef4444}',
  '*{box-sizing:border-box}',
  'body{margin:0;background:var(--bg);color:var(--ink);',
  'font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}',
  'header{display:flex;align-items:center;justify-content:space-between;gap:.75rem;',
  'padding:.9rem 1rem;background:var(--panel);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}',
  'header .title{font-weight:650;font-size:1.05rem}',
  'header .who{color:var(--muted);font-size:.85rem}',
  'header a{color:var(--muted);font-size:.85rem;text-decoration:none;border:1px solid var(--line);',
  'padding:.3rem .6rem;border-radius:.4rem}',
  'main{padding:1rem;max-width:40rem;margin:0 auto}',
  '.crumbs{color:var(--muted);font-size:.85rem;margin-bottom:.75rem}',
  '.step{display:flex;gap:.5rem;margin:0 0 1.1rem;list-style:none;padding:0;font-size:.8rem}',
  '.step li{flex:1;padding:.35rem .5rem;border-radius:.4rem;text-align:center;',
  'background:#161b25;color:var(--muted);border:1px solid var(--line)}',
  '.step li.done{color:var(--ok);border-color:#1f4030}',
  '.step li.now{color:var(--ink);border-color:var(--accent);background:#16233a}',
  '.card{background:var(--panel);border:1px solid var(--line);border-radius:.75rem;padding:1rem;margin-bottom:1rem}',
  '.card h2{margin:0 0 .25rem;font-size:1rem}',
  '.card p{margin:0;color:var(--muted);font-size:.9rem}',
  'dl{display:grid;grid-template-columns:auto 1fr;gap:.3rem .9rem;margin:.75rem 0 0}',
  'dt{color:var(--muted);font-size:.85rem}',
  'dd{margin:0;font-variant-numeric:tabular-nums}',
  'label{display:block;font-weight:600;margin-bottom:.4rem}',
  'input[type=text],input[type=number]{width:100%;padding:.95rem 1rem;font-size:1.35rem;',
  'font-variant-numeric:tabular-nums;letter-spacing:.02em;background:#0c0f15;color:var(--ink);',
  'border:2px solid var(--accent);border-radius:.6rem}',
  'input:focus{outline:3px solid rgba(59,130,246,.35)}',
  '.btnrow{display:flex;gap:.6rem;margin-top:1rem}',
  'button{flex:1;padding:1.05rem 1rem;font-size:1.05rem;font-weight:650;border-radius:.6rem;',
  'border:1px solid var(--line);background:#232b3a;color:var(--ink);cursor:pointer}',
  'button.primary{background:var(--accent);border-color:var(--accent);color:#fff}',
  '.hint{color:var(--muted);font-size:.85rem;margin-top:.6rem}',
  '.flash{padding:.75rem 1rem;border-radius:.6rem;margin-bottom:1rem;font-weight:600}',
  '.flash.info{background:#16233a;border:1px solid var(--accent)}',
  '.flash.ok{background:#12301f;border:1px solid var(--ok);color:#b7f3cd}',
  '.flash.warn{background:#33270c;border:1px solid var(--warn);color:#fde3b0}',
  '.flash.bad{background:#360f11;border:1px solid var(--bad);color:#ffc9cb}',
  'table{width:100%;border-collapse:collapse;margin-top:.5rem;font-size:.9rem}',
  'th{text-align:left;color:var(--muted);font-weight:600;padding:.4rem .3rem;border-bottom:1px solid var(--line)}',
  'td{padding:.5rem .3rem;border-bottom:1px solid #222836;font-variant-numeric:tabular-nums}',
  'tr.now td{background:#16233a}',
  '.tiles{display:grid;grid-template-columns:1fr 1fr;gap:.7rem}',
  '.tile{display:block;text-align:center;text-decoration:none;color:var(--ink);background:var(--panel);',
  'border:1px solid var(--line);border-radius:.75rem;padding:1.3rem .8rem}',
  '.tile .n{display:block;font-size:1.9rem;font-weight:700;font-variant-numeric:tabular-nums}',
  '.tile .l{display:block;color:var(--muted);font-size:.85rem;margin-top:.2rem}',
  '.big{font-size:2.4rem;font-weight:700;font-variant-numeric:tabular-nums}'
].join('');

// A handheld scanner is a keyboard: it types the code and sends Enter. So the
// only script the whole application needs is one that keeps the input focused,
// including after a page transition or a stray tap.
const FOCUS_JS = "var b=document.getElementById('code');if(b){b.focus();"
  + "document.addEventListener('click',function(){b.focus();});}";

// Emits the hidden `t` field carrying the session token, on every form that
// runs after login. Empty (no field at all) before login, since there is no
// token yet -- the manual badge form and the quick-login buttons don't need
// one.
function tokenField() {
  return token ? "<input type='hidden' name='t' value='" + esc(token) + "'>" : '';
}

function steps(labels, activeIndex) {
  let out = "<ol class='step'>";
  for (let i = 0; i < labels.length; i++) {
    const cls = i < activeIndex ? 'done' : (i === activeIndex ? 'now' : '');
    out += "<li class='" + cls + "'>" + esc(labels[i]) + '</li>';
  }
  return out + '</ol>';
}

// One scan box, one form. `action` names the transition the handler should
// apply; the handler never has to guess from the value alone.
function scanForm(label, hint, action, numeric, value) {
  return "<form method='post' action='/webhook/wms/scan'>"
    + "<input type='hidden' name='action' value='" + esc(action) + "'>"
    + tokenField()
    + "<label for='code'>" + esc(label) + '</label>'
    + "<input id='code' name='code' type='" + (numeric ? 'number' : 'text') + "'"
    + (numeric ? " inputmode='numeric' min='0'" : " inputmode='numeric' autocomplete='off'"
        + " autocapitalize='off' autocorrect='off' spellcheck='false'")
    + " value='" + esc(value === undefined ? '' : value) + "'"
    + " autofocus placeholder='" + (numeric ? 'Enter quantity' : 'Scan now') + "'>"
    + "<div class='btnrow'>"
    + "<button type='submit' class='primary'>Confirm</button>"
    + '</div>'
    + (hint ? "<p class='hint'>" + esc(hint) + '</p>' : '')
    + '</form>';
}

function cancelForm(label) {
  return "<form method='post' action='/webhook/wms/scan' style='margin-top:.6rem'>"
    + "<input type='hidden' name='action' value='cancel'>"
    + tokenField()
    + "<div class='btnrow'><button type='submit'>" + esc(label || 'Cancel') + '</button></div>'
    + '</form>';
}

// One-click sign-in for demos: the same POST shape scanForm() produces for a
// typed badge, just with the code baked into the button instead of typed. No
// changes needed anywhere else -- the scan handler can't tell the difference.
function badgeButton(code, name, role) {
  return "<form method='post' action='/webhook/wms/scan'>"
    + "<input type='hidden' name='action' value='login'>"
    + "<input type='hidden' name='code' value='" + esc(code) + "'>"
    + "<button class='tile' type='submit'><span class='n'>" + esc(name)
    + "</span><span class='l'>" + esc(role) + '</span></button></form>';
}

// ---------------------------------------------------------------- screens

function screenLogin() {
  const quickLogin = "<div class='card'><h2>Quick demo sign-in</h2>"
    + '<p>Skip the badge scan and sign in directly as one of the demo operators.</p></div>'
    + "<div class='tiles'>"
    + badgeButton('BADGE-1001', 'Marijke Bakker', 'Operator')
    + badgeButton('BADGE-1002', 'Tom', 'Operator')
    + badgeButton('BADGE-1003', 'Sara Yilmaz', 'Supervisor')
    + '</div>';
  return {
    title: 'Sign in',
    header: 'WMS terminal',
    who: '',
    body: quickLogin
      + "<div class='card'><h2>Or scan your badge</h2>"
      + '<p>Hold the badge under the scanner, or type the badge number and press Enter.</p></div>'
      + scanForm('Badge', 'Demo badges: BADGE-1001, BADGE-1002, BADGE-1003', 'login', false)
  };
}

// Menu entries are POST forms, not links. Starting a task mutates the session,
// and a GET that changes state breaks the moment a scanner's browser prefetches
// a link or an operator hits back.
function tile(action, count, label) {
  return "<form method='post' action='/webhook/wms/scan'>"
    + "<input type='hidden' name='action' value='" + esc(action) + "'>"
    + tokenField()
    + "<button class='tile' type='submit'><span class='n'>" + esc(count)
    + "</span><span class='l'>" + esc(label) + '</span></button></form>';
}

function screenMenu() {
  const body = "<div class='tiles'>"
    + tile('start_receive', data.open_receipts || 0, 'Lines to receive')
    + tile('start_pick', data.open_picks || 0, 'Picks waiting')
    + tile('start_lookup', '⌕', 'Stock lookup')
    + '</div>'
    + "<p class='hint'>" + esc(data.open_putaways || 0)
    + ' put-away task(s) open &mdash; put-away is documented but not built in this PoC.</p>';
  return { title: 'Menu', header: 'What next?', who: userName, body: body };
}

function screenReceiving() {
  const lines = data.lines || [];
  const cur = data.current_line;
  let table = '';
  if (lines.length) {
    // The barcode column is not decoration. Listing only the SKU meant the
    // screen showed "SKU-1004" while the thing that actually works is
    // "4000000001004" -- so anyone driving the demo by hand typed the SKU and
    // got "unknown barcode" with no way to discover why. A real operator with a
    // scanner never hits this; every human evaluating the system does.
    table = "<div class='card'><h2>Open lines</h2><table><tr><th>#</th><th>Article</th>"
      + '<th>Scan this</th><th>Open</th></tr>';
    for (const l of lines) {
      const isNow = cur && Number(cur.po_line_id) === Number(l.po_line_id);
      table += "<tr class='" + (isNow ? 'now' : '') + "'><td>" + esc(l.line_number) + '</td><td>'
        + esc(l.product_name) + '<br><span style=\'color:#9aa7bd;font-size:.8rem\'>'
        + esc(l.sku) + '</span></td>'
        + "<td><code style='font-size:.95rem;letter-spacing:.03em'>"
        + esc(l.barcode || '-') + '</code></td>'
        + '<td>' + esc(l.open_qty) + '</td></tr>';
    }
    table += '</table></div>';
  }

  const crumbs = "<div class='crumbs'>Purchase order <strong>" + esc(data.order_number || '')
    + '</strong> &middot; ' + esc(data.vendor || '') + '</div>';

  if (state === 'receiving_await_po') {
    return {
      title: 'Receive', header: 'Receive goods', who: userName,
      body: steps(['Order', 'Item', 'Quantity'], 0)
        + "<div class='card'><h2>Scan the purchase order</h2>"
        + '<p>Scan the barcode on the delivery paperwork.</p></div>'
        + scanForm('Purchase order', 'Demo order: PO-1042', 'receive_po', false)
        + cancelForm('Back to menu')
    };
  }

  if (state === 'receiving_await_item') {
    return {
      title: 'Receive', header: 'Receive goods', who: userName,
      body: crumbs + steps(['Order', 'Item', 'Quantity'], 1)
        + "<div class='card'><h2>Scan the article</h2>"
        + '<p>Scan any article listed below.</p></div>'
        + scanForm('Article barcode', '', 'receive_item', false)
        + table + cancelForm('Finish order')
    };
  }

  // receiving_await_qty
  return {
    title: 'Receive', header: 'Receive goods', who: userName,
    body: crumbs + steps(['Order', 'Item', 'Quantity'], 2)
      + "<div class='card'><h2>" + esc(cur ? cur.product_name : 'Article') + '</h2>'
      + "<p>How many are you putting away?</p><dl><dt>Article</dt><dd>"
      + esc(cur ? cur.sku : '') + '</dd><dt>Still expected</dt><dd>'
      + esc(cur ? cur.open_qty : '') + '</dd></dl></div>'
      + scanForm('Quantity received', 'Press Enter to confirm', 'receive_qty', true,
                 cur ? cur.open_qty : '')
      + cancelForm('Different article')
  };
}

function screenPicking() {
  const crumbs = "<div class='crumbs'>Order <strong>" + esc(data.order_number || '')
    + '</strong> &middot; ' + esc(data.customer || '') + ' &middot; '
    + esc(data.remaining_tasks || 0) + ' task(s) left</div>';

  const detail = "<div class='card'><h2>" + esc(data.product_name || '') + '</h2>'
    + '<dl><dt>Article</dt><dd>' + esc(data.sku || '') + '</dd>'
    + '<dt>Location</dt><dd>' + esc(data.location_code || '') + '</dd>'
    + '<dt>To pick</dt><dd>' + esc(data.qty || 0) + '</dd>'
    + '<dt>System says on shelf</dt><dd>' + esc(data.on_hand || 0) + '</dd></dl></div>';

  if (state === 'picking_await_location') {
    return {
      title: 'Pick', header: 'Pick order', who: userName,
      body: crumbs + steps(['Location', 'Article', 'Quantity'], 0)
        + "<div class='card'><h2>Go to " + esc(data.location_code || '') + '</h2>'
        + '<p>Scan the shelf label to confirm you are in the right place.</p>'
        + "<dl><dt>Scan this</dt><dd><code>" + esc(data.location_barcode || '') + '</code></dd></dl>'
        + '</div>'
        + scanForm('Location', 'Shelf labels look like LOC-A-01-2', 'pick_location', false)
        + detail + cancelForm('Back to menu')
    };
  }

  if (state === 'picking_await_item') {
    return {
      title: 'Pick', header: 'Pick order', who: userName,
      body: crumbs + steps(['Location', 'Article', 'Quantity'], 1)
        + "<div class='card'><h2>Scan the article</h2>"
        + '<p>Confirm you picked up the right thing.</p>'
        + "<dl><dt>Article</dt><dd>" + esc(data.product_name || '') + '</dd>'
        + '<dt>Scan this</dt><dd><code>' + esc(data.product_barcode || '') + '</code></dd></dl>'
        + '</div>'
        + scanForm('Article barcode', '', 'pick_item', false)
        + detail + cancelForm('Back to menu')
    };
  }

  // picking_await_qty
  return {
    title: 'Pick', header: 'Pick order', who: userName,
    body: crumbs + steps(['Location', 'Article', 'Quantity'], 2)
      + detail
      + scanForm('Quantity picked', 'Enter what you actually found, even if it is fewer',
                 'pick_qty', true, data.qty)
      + cancelForm('Back to menu')
  };
}

function screenLookup() {
  const p = data.product;
  let result = '';
  if (p) {
    result = "<div class='card'><h2>" + esc(p.name) + '</h2><p>' + esc(p.sku) + '</p>'
      + "<div class='big'>" + esc(p.total) + ' <span style=\'font-size:1rem;color:#9aa7bd\'>'
      + esc(p.uom) + '</span></div>';
    const locs = p.locations || [];
    if (locs.length) {
      result += '<table><tr><th>Location</th><th>Kind</th><th>Qty</th></tr>';
      for (const l of locs) {
        result += '<tr><td>' + esc(l.location_code) + '</td><td>' + esc(l.location_kind)
          + '</td><td>' + esc(l.qty) + '</td></tr>';
      }
      result += '</table>';
    } else {
      result += "<p style='margin-top:.6rem'>No stock anywhere.</p>";
    }
    result += '</div>';
  }
  return {
    title: 'Stock lookup', header: 'Stock lookup', who: userName,
    body: "<div class='card'><h2>Scan an article</h2><p>Shows every location holding it.</p></div>"
      + scanForm('Article barcode', '', 'lookup_item', false)
      + result + cancelForm('Back to menu')
  };
}

// ---------------------------------------------------------------- dispatch

let screen;
if (state === 'login') screen = screenLogin();
else if (state === 'idle') screen = screenMenu();
else if (state.indexOf('receiving_') === 0) screen = screenReceiving();
else if (state.indexOf('picking_') === 0) screen = screenPicking();
else if (state === 'lookup') screen = screenLookup();
else screen = screenLogin();

const flashHtml = flash
  ? "<div class='flash " + esc(flashKind) + "'>" + esc(flash) + '</div>'
  : '';

const logout = state === 'login' ? ''
  : "<form method='post' action='/webhook/wms/scan' style='margin:0'>"
    + "<input type='hidden' name='action' value='logout'>"
    + tokenField()
    + "<button type='submit' style='flex:0;padding:.3rem .6rem;font-size:.85rem;"
    + "font-weight:400;color:#9aa7bd'>Sign out</button></form>";

const html = '<!doctype html>\n<html lang="en">\n<head>\n'
  + '<meta charset="utf-8">\n'
  + '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
  + '<title>' + esc(screen.title) + ' &middot; WMS</title>\n'
  + '<style>' + CSS + '</style>\n</head>\n<body>\n'
  + '<header><span class="title">' + esc(screen.header) + '</span>'
  + (screen.who ? '<span class="who">' + esc(screen.who) + '</span>' : '')
  + logout + '</header>\n<main>\n' + flashHtml + screen.body + '\n</main>\n'
  + '<script>' + FOCUS_JS + '</scr' + 'ipt>\n</body>\n</html>';

return [{ json: { html: html } }];
