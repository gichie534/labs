#!/usr/bin/env bash
# Step 1 — dump the source: the database (custom format) and the generated application-role script.
#
# Env: SOURCE_URL (libpq URL of the source `app` DB), WORKDIR (artifact dir, default ./_migration).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_URL:?set SOURCE_URL to the source app-database libpq URL}"
WORKDIR="${WORKDIR:-./_migration}"
mkdir -p "$WORKDIR"

echo "==> Generating application roles from the source catalog"
psql "$SOURCE_URL" -X -tAq -v ON_ERROR_STOP=1 -f "$HERE/gen_roles.sql" > "$WORKDIR/roles.gen.sql"
echo "    wrote $WORKDIR/roles.gen.sql ($(grep -c ';' "$WORKDIR/roles.gen.sql" || true) statements)"

echo "==> Dumping the database in custom format (schema + data)"
pg_dump "$SOURCE_URL" -Fc -Z6 -f "$WORKDIR/app.dump"
echo "    wrote $WORKDIR/app.dump"

echo "Dump complete."
