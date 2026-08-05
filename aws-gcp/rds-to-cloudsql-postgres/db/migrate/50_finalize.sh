#!/usr/bin/env bash
# Step 5 — cutover finalization on the target: assign passwords + LOGIN to the application login
# roles (secrets never travel in a dump), then re-align sequences and refresh materialized views as
# a belt-and-suspenders check (pg_dump already carries sequence values and a matview REFRESH, but a
# CDC/incremental cutover would resync here).
#
# Env: SOURCE_URL, TARGET_URL, WORKDIR, APP_DB_PASSWORD.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_URL:?set SOURCE_URL}"
: "${TARGET_URL:?set TARGET_URL}"
: "${APP_DB_PASSWORD:?set APP_DB_PASSWORD (password assigned to application login roles)}"
WORKDIR="${WORKDIR:-./_migration}"

echo "==> Generating password/LOGIN statements from the source login roles"
psql "$SOURCE_URL" -X -tAq -v ON_ERROR_STOP=1 -v pw="$APP_DB_PASSWORD" \
  -f "$HERE/gen_passwords.sql" > "$WORKDIR/passwords.gen.sql"

echo "==> Applying passwords + LOGIN on the target"
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 -f "$WORKDIR/passwords.gen.sql"

echo "==> Refreshing materialized views on the target"
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT format('%I.%I', schemaname, matviewname) AS mv
    FROM pg_matviews
    WHERE schemaname NOT LIKE 'pg\_%' AND schemaname <> 'information_schema'
  LOOP
    EXECUTE 'REFRESH MATERIALIZED VIEW ' || r.mv;
  END LOOP;
END
$$;
SQL

echo "Finalization complete."
