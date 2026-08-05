#!/usr/bin/env bash
# Run the full migration in order: dump -> load roles -> restore -> reassign owners -> finalize.
# Each step is independently runnable (and re-runnable) for a real, staged production cutover; this
# wrapper is the lab's one-shot path.
#
# Env: SOURCE_URL, TARGET_URL, WORKDIR, APP_DB_PASSWORD (see the individual scripts).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/10_dump.sh"
"$HERE/20_load_roles.sh"
"$HERE/30_restore.sh"
"$HERE/40_reassign_owners.sh"
"$HERE/50_finalize.sh"

echo
echo "Migration finished. Run the parity check next:  task verify"
