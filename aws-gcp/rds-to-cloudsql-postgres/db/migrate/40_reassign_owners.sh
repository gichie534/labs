#!/usr/bin/env bash
# Step 4 — reassign object ownership on the target to the real (application) owners, generated from
# the source catalog. Objects were restored owned by the admin (--no-owner); this restores the true
# ownership graph without any hand-maintained list.
#
# Env: SOURCE_URL, TARGET_URL, WORKDIR.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_URL:?set SOURCE_URL}"
: "${TARGET_URL:?set TARGET_URL}"
WORKDIR="${WORKDIR:-./_migration}"

echo "==> Generating ownership statements from the source catalog"
psql "$SOURCE_URL" -X -tAq -v ON_ERROR_STOP=1 -f "$HERE/gen_owners.sql" > "$WORKDIR/owners.gen.sql"
echo "    wrote $WORKDIR/owners.gen.sql ($(grep -c ';' "$WORKDIR/owners.gen.sql" || true) statements)"

echo "==> Applying ownership on the target"
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 -f "$WORKDIR/owners.gen.sql"

echo "Ownership reassigned."
