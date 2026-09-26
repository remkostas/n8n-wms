// Builds the 303 target after a scan. Runs in the "Build Redirect" Code node.
//
// Post/redirect/get: the scan was a POST, the answer is a redirect to a pure GET.
// Refreshing the resulting page therefore re-runs a read, never a second scan --
// which is the whole reason "recovery after refresh" needs no special handling.
//
// (scripts/build_workflows.py prepends redirect_base.js, which defines terminalUrl().)

const state = $('Next State').first().json;
const req = $('Scan Submit').first().json;
const token = $('Read Request').first().json.token;

// The flash message rides in the query string rather than in the session,
// because storing it would mean an extra write on every single scan purely to
// say "OK".
const params = [];
if (state.msg) {
  params.push('msg=' + encodeURIComponent(state.msg));
  params.push('kind=' + encodeURIComponent(state.kind || 'info'));
}

// Carries the session forward in the URL too, not just the cookie: n8n's
// webhook CSP sandbox makes the page an opaque origin, and opaque origins
// only get cookies attached on top-level GET navigations -- never on the form
// POST a scan or menu tap makes. Behind a proxy that strips the CSP header
// the cookie does the job alone; this `t` param plus the matching hidden
// field Render Screen adds to every form is what keeps a stock, sandboxed
// n8n working past the very first click.
// Omitted on logout -- clearing the cookie should also end the URL-carried
// session, not leave it recoverable from browser history.
if (token && state.clear_cookie !== true) {
  params.push('t=' + encodeURIComponent(token));
}

// Cache-busting is not cosmetic here: some handheld browsers will happily
// serve the previous screen from cache after a redirect, which looks to the
// operator like the scan did nothing. Separate key from `t` above -- this one
// must change on every request even when the token doesn't, or it stops
// busting the cache.
params.push('cb=' + Date.now());

const out = { location: terminalUrl(req, params) };

// Signing out is the one non-login response that touches the cookie.
if (state.clear_cookie === true) {
  out.cookie = 'wms_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax';
}

return [{ json: out }];
