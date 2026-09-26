#!/usr/bin/env bash
# Turn a fresh `docker compose up` into a working terminal with no UI clicks:
#
#   1. create the n8n owner account (skipped if one exists)
#   2. mint an API key for the public REST API
#   3. create the Postgres credential the workflows use
#   4. build the workflows from src/terminal/*.js and import them, replacing any
#      previous copies, then activate them
#
# Safe to re-run: that is also how a change to src/terminal/ gets deployed.
# Requires curl, jq and python3.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

STATE="$REPO_ROOT/.setup-state"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

: "${N8N_OWNER_EMAIL:?set N8N_OWNER_EMAIL in .env}"
: "${N8N_OWNER_PASSWORD:?set N8N_OWNER_PASSWORD in .env}"
: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'setup: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- wait for n8n

# /healthz/readiness, not /healthz: on first boot /healthz answers 200 while n8n
# is still migrating its database, and every /rest call in that window returns
# a plain-text "n8n is starting up" page instead of JSON.
say "waiting for n8n at $N8N_URL"
for _ in $(seq 1 90); do
  curl -sf "$N8N_URL/healthz/readiness" >/dev/null && break
  sleep 2
done
curl -sf "$N8N_URL/healthz/readiness" >/dev/null || die "n8n did not come up (docker compose logs n8n)"

# ---------------------------------------------------------------- owner + login

rest() {  # rest METHOD PATH [JSON] -- internal API, authenticated by the login cookie
  curl -sS -b "$JAR" -c "$JAR" -X "$1" "$N8N_URL/rest$2" \
    -H 'Content-Type: application/json' ${3:+-d "$3"}
}

if [ "$(curl -sf "$N8N_URL/rest/settings" | jq -r '.data.userManagement.showSetupOnFirstLoad')" = "true" ]; then
  say "creating owner account $N8N_OWNER_EMAIL"
  rest POST /owner/setup "$(jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" \
    '{email:$e, password:$p, firstName:"Demo", lastName:"Owner"}')" | jq -e '.data.id' >/dev/null \
    || die "owner setup failed"
fi

rest POST /login "$(jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" \
  '{emailOrLdapLoginId:$e, password:$p}')" | jq -e '.data.id' >/dev/null \
  || die "login failed -- does N8N_OWNER_PASSWORD match the existing owner?"

# ---------------------------------------------------------------- API key

API_KEY=""
[ -f "$STATE" ] && API_KEY="$(jq -r '.api_key // empty' "$STATE")"
if [ -z "$API_KEY" ] || ! curl -sf "$N8N_URL/api/v1/workflows?limit=1" -H "X-N8N-API-KEY: $API_KEY" >/dev/null; then
  say "creating API key"
  scopes="$(rest GET /api-keys/scopes | jq -c '.data')"
  API_KEY="$(rest POST /api-keys "$(jq -n --argjson s "$scopes" \
    '{label:"n8n-wms setup", scopes:$s, expiresAt:null}')" | jq -r '.data.rawApiKey // .data.apiKey // empty')"
  [ -n "$API_KEY" ] || die "could not create an API key"
fi

api() {  # api METHOD PATH [JSON-FILE|JSON] -- public API
  local data=()
  if [ -n "${3:-}" ]; then
    if [ -f "$3" ]; then data=(--data-binary "@$3"); else data=(-d "$3"); fi
  fi
  curl -sS -X "$1" "$N8N_URL/api/v1$2" -H "X-N8N-API-KEY: $API_KEY" \
    -H 'Content-Type: application/json' "${data[@]}"
}

# ---------------------------------------------------------------- credential

CRED_ID=""
[ -f "$STATE" ] && CRED_ID="$(jq -r '.credential_id // empty' "$STATE")"
if [ -z "$CRED_ID" ] || [ "$(rest GET "/credentials/$CRED_ID" | jq -r '.data.id // empty')" != "$CRED_ID" ]; then
  say "creating Postgres credential"
  # Host and port are the compose-internal ones: n8n talks to postgres over the
  # compose network, not the published port.
  CRED_ID="$(api POST /credentials "$(jq -n --arg u "$POSTGRES_USER" --arg p "$POSTGRES_PASSWORD" '{
      name: "WMS Postgres", type: "postgres",
      data: {host:"postgres", port:5432, database:"wms", user:$u, password:$p,
             ssl:"disable", allowUnauthorizedCerts:false, sshTunnel:false,
             maxConnections:100}
    }')" | jq -r '.id // empty')"
  [ -n "$CRED_ID" ] || die "could not create the Postgres credential"
fi

jq -n --arg k "$API_KEY" --arg c "$CRED_ID" '{api_key:$k, credential_id:$c}' > "$STATE"
chmod 600 "$STATE"

# ---------------------------------------------------------------- workflows

python3 "$REPO_ROOT/scripts/build_workflows.py" "$CRED_ID" >/dev/null

for wf in "$REPO_ROOT"/workflows/dist/*.json; do
  name="$(jq -r .name "$wf")"
  # Replace rather than update: import is the one path that is identical on a
  # fresh instance and on a re-run.
  for old in $(api GET "/workflows?limit=250" | jq -r --arg n "$name" '.data[] | select(.name==$n) | .id'); do
    api POST "/workflows/$old/deactivate" >/dev/null || true
    api DELETE "/workflows/$old" >/dev/null
  done
  id="$(api POST /workflows "$wf" | jq -r '.id // empty')"
  [ -n "$id" ] || die "import failed for $name"
  api POST "/workflows/$id/activate" | jq -e '.active == true' >/dev/null || die "could not activate $name"
  say "imported and activated: $name ($id)"
done

# ---------------------------------------------------------------- smoke test

if curl -sf "$TERMINAL_URL" | grep -q 'Sign in'; then
  say "terminal is up: $TERMINAL_URL  (sign in with one of the demo operators)"
else
  die "workflows are active but $TERMINAL_URL did not render the sign-in screen"
fi
