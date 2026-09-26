#!/usr/bin/env bash
# Drop the wms schema and rebuild it from db/01-03: schema, functions, demo data.
#
# DESTRUCTIVE. Every order, movement and live operator session is deleted;
# anyone with the terminal open is sent back to the badge screen. Only meant for
# the demo stack in this repo, so it refuses any database that is not on this
# machine unless you set I_KNOW_THIS_IS_DESTRUCTIVE=1.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

host="${POSTGRES_BIND%:*}"
case "$host" in
  127.0.0.1|localhost|::1) ;;
  *)
    if [ "${I_KNOW_THIS_IS_DESTRUCTIVE:-}" != "1" ]; then
      echo "refusing: $POSTGRES_BIND is not a loopback address." >&2
      echo "This drops the whole wms schema. Set I_KNOW_THIS_IS_DESTRUCTIVE=1 if that is really what you want." >&2
      exit 1
    fi
    ;;
esac

wms_psql -c 'DROP SCHEMA IF EXISTS wms CASCADE;' 2>/dev/null
for f in 01-schema.sql 02-functions.sql 03-seed.sql; do
  wms_psql -f - < "$REPO_ROOT/db/$f" >/dev/null
done
echo "wms schema rebuilt: $(wms_sql 'SELECT count(*) FROM wms.products') products, $(wms_sql "SELECT count(*) FROM wms.pick_tasks WHERE status='open'") open pick tasks"
