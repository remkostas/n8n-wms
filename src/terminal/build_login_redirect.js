// Issues the session cookie after a badge scan. Runs in the "Build Login
// Redirect" Code node.
//
// This is the only place in the system that mints a cookie, and every attribute
// on it is set by hand. n8n has no cookie helper, no signed-cookie support and no
// CSRF machinery, so the security properties of the session are exactly as good
// as this file and no better -- worth stating plainly in a feasibility review.
//
// (scripts/build_workflows.py prepends redirect_base.js, which defines terminalUrl().)

const row = $input.first().json || {};
const req = $('Scan Submit').first().json;

// wms.session_start returns no rows for an unknown or deactivated badge.
// alwaysOutputData turns that into a synthetic empty item, so the check has to
// be for the token field rather than for an empty result set.
if (!row.token) {
  return [{ json: {
    location: terminalUrl(req, [
      'msg=' + encodeURIComponent('Badge not recognised.'),
      'kind=bad', 'cb=' + Date.now()
    ]),
    // Cleared rather than omitted: a stale cookie from a previous operator must
    // not survive a failed sign-in on a shared handheld.
    cookie: 'wms_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax'
  } }];
}

// No Secure attribute: this PoC is served over plain HTTP on localhost. A real
// deployment terminates TLS at the reverse proxy and MUST add it -- without it
// the session token crosses the warehouse Wi-Fi in clear text.
const cookie = 'wms_session=' + encodeURIComponent(row.token)
  + '; Path=/; Max-Age=43200; HttpOnly; SameSite=Lax';

return [{ json: {
  location: terminalUrl(req, [
    'msg=' + encodeURIComponent('Signed in as ' + (row.user_name || '')),
    'kind=ok',
    // Carries the new session in the URL too -- see Build Redirect for why
    // the cookie alone isn't enough while n8n's CSP sandbox is in
    // place.
    't=' + encodeURIComponent(row.token),
    'cb=' + Date.now()
  ]),
  cookie: cookie
} }];
