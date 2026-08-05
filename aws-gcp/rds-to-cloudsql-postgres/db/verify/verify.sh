#!/usr/bin/env bash
# Parity gate: run parity.sql against source and target with identical, stable formatting and diff
# the results. Zero diff => the migration reproduced structure + content exactly (exit 0). Any diff
# is printed and the script exits non-zero — red/green discipline for infrastructure.
#
# Env: SOURCE_URL, TARGET_URL, WORKDIR (default ./_migration).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_URL:?set SOURCE_URL}"
: "${TARGET_URL:?set TARGET_URL}"
WORKDIR="${WORKDIR:-./_migration}"
mkdir -p "$WORKDIR"

PSQL_FMT=(-X -A -F $'\t' -P pager=off -v ON_ERROR_STOP=1 -f "$HERE/parity.sql")

echo "==> Collecting parity snapshot from SOURCE"
psql "$SOURCE_URL" "${PSQL_FMT[@]}" > "$WORKDIR/source.parity"

echo "==> Collecting parity snapshot from TARGET"
psql "$TARGET_URL" "${PSQL_FMT[@]}" > "$WORKDIR/target.parity"

echo "==> Diffing (source vs target)"
if diff -u "$WORKDIR/source.parity" "$WORKDIR/target.parity"; then
  echo
  echo "PARITY OK — source and target are structurally + content identical."
  echo "(For version/size/extension/privilege detail, run migration_verification.sql manually.)"
else
  echo
  echo "PARITY MISMATCH — see the diff above. Left = source (RDS), right = target (Cloud SQL)." >&2
  exit 1
fi
