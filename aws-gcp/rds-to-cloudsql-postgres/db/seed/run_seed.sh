#!/usr/bin/env bash
# Apply the seed SQL, in order, to the SOURCE database. Run on the migration host (which can reach
# RDS) — see the Taskfile `seed` task.
#
# Env: SOURCE_URL (source app-database libpq/conninfo string).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_URL:?set SOURCE_URL to the source app-database connection string}"

for f in 00_roles 01_extensions 02_schema 03_grants 04_data; do
  echo "==> $f.sql"
  psql "$SOURCE_URL" -X -v ON_ERROR_STOP=1 -f "$HERE/$f.sql"
done

echo "Seed complete."
