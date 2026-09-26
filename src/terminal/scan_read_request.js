// Pulls the session token out of the request cookie, falling back to the `t`
// form field when there's no usable cookie. Runs as the first Code node in
// both the terminal and the scan handler.
//
// n8n has no session primitive: no cookie helper, no signed-cookie support, no
// CSRF token, nothing between the raw Cookie header and application code. Every
// line below is boilerplate that a web framework would have provided, and it has
// to be written -- and kept correct -- once per workflow that needs a session.
// That is a real finding about building an authenticated application on n8n,
// not incidental plumbing.

const req = $input.first().json;
const headers = req.headers || {};
const raw = headers.cookie || headers.Cookie || '';

// Deliberately hand-rolled rather than split(';').map(...): cookie values can
// contain '=' (base64, signatures), so only the FIRST '=' separates name from
// value. Splitting on every '=' silently truncates such tokens.
const cookies = {};
for (const part of String(raw).split(';')) {
  const s = part.trim();
  if (!s) continue;
  const eq = s.indexOf('=');
  if (eq < 1) continue;
  // Every cookie for this host arrives here, not just ours, and one malformed
  // %-escape in any of them would make decodeURIComponent throw and take the
  // whole terminal down with a 500. Keep the raw value instead.
  let value = s.slice(eq + 1);
  try { value = decodeURIComponent(value); } catch (e) { /* keep it raw */ }
  cookies[s.slice(0, eq)] = value;
}

// The `t` form field (added by Render Screen to every authenticated form) is
// how the session survives n8n's webhook CSP sandbox: the sandbox makes the
// page an opaque origin, and opaque origins only get cookies attached on
// top-level GET navigations -- never on the form POST a scan or menu tap
// makes. Behind a proxy that strips that CSP header the cookie works on its
// own, so it stays the primary source; the form field is the fallback that
// makes a stock, sandboxed n8n work too. See docs/csp-sandbox.md.
const body = req.body || {};
const token = cookies.wms_session || body.t || '';

return [{ json: {
  token: token,
  // Passed through so the screen_data query parameter is never null: the
  // Postgres node's comma-split parameter binding treats an empty segment as a
  // missing parameter rather than an empty string.
  token_param: token || '-',
  has_session: token.length > 0
} }];
