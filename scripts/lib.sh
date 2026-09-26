# shellcheck shell=bash
# Shared by scripts/, tests/ and bench/. Source it; don't run it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# .env is optional: every value has the same default compose.yml uses. A
# variable already set in the environment wins over .env, so a one-off
# `POSTGRES_BIND=... scripts/reset-db.sh` really targets what it says.
if [ -f "$REPO_ROOT/.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    [ -n "${!key+x}" ] || export "$key=$value"
  done < "$REPO_ROOT/.env"
fi

POSTGRES_USER="${POSTGRES_USER:-wms}"
N8N_BIND="${N8N_BIND:-127.0.0.1:5678}"
POSTGRES_BIND="${POSTGRES_BIND:-127.0.0.1:55432}"
N8N_URL="${N8N_URL:-http://$N8N_BIND}"
# shellcheck disable=SC2034  # used by the scripts that source this file
TERMINAL_URL="$N8N_URL/webhook/wms"

# psql against the wms database. Uses a local psql client over the published
# port when one is installed, otherwise runs psql inside the container, so
# nothing beyond Docker is required.
wms_psql() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 \
      -h "${POSTGRES_BIND%:*}" -p "${POSTGRES_BIND##*:}" -U "$POSTGRES_USER" -d wms "$@"
  else
    docker compose -f "$REPO_ROOT/compose.yml" exec -T postgres \
      psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d wms "$@"
  fi
}

# One value from one query, whitespace-trimmed.
wms_sql() {
  wms_psql -t -A -c "$1" | tr -d '[:space:]'
}
