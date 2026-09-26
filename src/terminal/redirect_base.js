// Shared helper text, inlined into build_redirect.js and build_login_redirect.js
// by scripts/build_workflows.py. Kept in its own file so the two copies cannot drift.
//
// WHY THIS EXISTS
//
// The Respond to Webhook node cannot be given a relative Location. Handed
// "/webhook/wms" it emits `location: https:///webhook/wms` -- scheme forced to
// https regardless of N8N_PROTOCOL, and an empty authority. Browsers and curl
// both treat that as a dead link, and because the redirect still returns a
// valid-looking 303 the failure is invisible from the response status: the
// mutation succeeded, the operator just never saw the next screen.
//
// So the absolute URL has to be rebuilt by hand from the request headers on
// every redirect. Deriving it from Host rather than hardcoding keeps the stack
// portable across localhost, a reverse proxy, and a customer's own
// hostname, which matters given the compose file is meant to be deployable.

function terminalUrl(req, params) {
  const h = (req && req.headers) || {};
  const host = h['x-forwarded-host'] || h.host || 'localhost:5678';
  const proto = h['x-forwarded-proto'] || 'http';
  const qs = params.length ? '?' + params.join('&') : '';
  return proto + '://' + host + '/webhook/wms' + qs;
}
