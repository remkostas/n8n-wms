# The bug the test suite couldn't see: n8n's webhook CSP sandbox

The automated acceptance suite had been green for days when I opened the terminal in an ordinary browser for the first time. Sign-in worked. Every scan after that sent me straight back to the badge screen with "Session expired".

It looked exactly like a session-timeout bug, and it wasn't one.

## What happens

n8n serves every HTML response from a webhook with this header:

```
Content-Security-Policy: sandbox allow-downloads allow-forms allow-modals allow-popups
  allow-scripts allow-top-navigation-by-user-activation …
```

`allow-same-origin` is deliberately missing. That puts the page in an **opaque origin**, and an opaque origin has no cookie jar of its own. The browser:

- accepts the `Set-Cookie` from the login redirect;
- sends the cookie on the next **top-level GET**, so the screen renders fine and shows the operator as signed in;
- sends **no cookie** on the **form POST** from inside that page, and sends `Origin: null` instead.

Every scan is a form POST, so every scan arrived without a session. The page stayed perfectly healthy until you pressed anything.

## Why the tests missed it

`curl` does not enforce CSP. It stores and sends cookies no matter what headers the page carries. The HTTP-level suite drove the same requests a browser would, but not with a browser's security rules, so this whole class of bug was invisible to it.

HTTPS doesn't change anything either: the header comes through untouched whatever the transport. I checked, because "it's probably because it's plain HTTP" was the first theory.

## Three ways out

| Fix | Cost |
|---|---|
| `N8N_INSECURE_DISABLE_WEBHOOK_IFRAME_SANDBOX=true` | Instance-wide. n8n named it *insecure* for a reason: the sandbox is what stops a compromised or careless workflow from serving, say, a credential-harvesting page from a trusted origin. Fine on a throwaway demo box; hard to defend on a shared or public instance. |
| A reverse proxy that strips the header for these paths only | The same security reduction, narrowed to the WMS paths. It keeps the sandbox for every other webhook on the instance, but it's easy to miss, and it doesn't travel to a customer's deployment unless their proxy does the same. |
| Stop relying on cookies: carry the token in the URL and a hidden form field | The only option that is safe on a stock, sandboxed instance. The cost is a session token in browser history and server logs. |

## What this repo does

Both of the last two approaches together, so it works either way:

1. **The cookie stays the primary carrier.** Behind a proxy that strips the CSP header, it's all that's needed.
2. **The token also travels as `t`:** as a query parameter on every redirect ([`src/terminal/build_redirect.js`](../src/terminal/build_redirect.js)) and as a hidden field on every form ([`src/terminal/render_screen.js`](../src/terminal/render_screen.js)). The request readers take the cookie first and fall back to `t`.
3. **Sign-out leaves `t` off**, so a signed-out session can't be revived from browser history.

So `compose.yml` runs **upstream n8n with the sandbox left on.** Section H of the acceptance test simulates the sandboxed browser by sending no cookies at all.

Checked in a real Chromium engine too, against the stock compose stack: a full receive → pick → short pick → lookup run made 20 form POSTs. **None of them carried the cookie**, 19 carried the token field (all but the sign-in POST, which has no session yet), and the session held from start to finish.

### If you would rather keep the token out of URLs

Put a proxy in front and strip the header for the terminal's paths only. Never add a catch-all: that would expose every webhook on the instance with its protection removed.

```nginx
location /webhook/wms {
  proxy_pass http://n8n:5678/webhook/wms;

  # Respond to Webhook can't emit a relative Location, so redirect_base.js
  # rebuilds absolute URLs from these. Without them every 303 points at n8n:5678.
  proxy_set_header Host              $http_host;
  proxy_set_header X-Forwarded-Host  $http_host;
  proxy_set_header X-Forwarded-Proto $scheme;

  proxy_hide_header Content-Security-Policy;
}

location / {
  return 404;
}
```

## What I would check in any browser-facing n8n app

Open DevTools → Network, submit a form, and click the POST:

- Is there a `Cookie` header **on the request**? If not, the session is being stripped.
- Is there a `content-security-policy: sandbox …` header on the page that submitted it? If so, expect exactly this bug.

That check takes two minutes. Finding the bug without it took hours.
