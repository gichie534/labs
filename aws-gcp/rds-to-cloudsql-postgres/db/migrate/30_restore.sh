#!/usr/bin/env bash
# Step 3 — restore the dump into the target in three sections (the production-proven order): schema
# (pre-data), rows (data, with triggers disabled and parallel jobs), then indexes/constraints/
# triggers/ACLs (post-data).
#
# --no-owner: objects land owned by the restore user; real owners are reassigned in step 4. ACLs are
# kept (no --no-acl) so the grants come along — every grantee role already exists from step 2.
# pre-data / post-data are tolerant (|| true): a benign "already exists" on re-run must not abort the
# far more important data load.
#
# Env: TARGET_URL, WORKDIR, JOBS (parallel restore jobs, default 4).
set -euo pipefail

: "${TARGET_URL:?set TARGET_URL to the target app-database libpq URL (as the admin user)}"
WORKDIR="${WORKDIR:-./_migration}"
JOBS="${JOBS:-4}"
DUMP="$WORKDIR/app.dump"
[ -f "$DUMP" ] || { echo "missing $DUMP — run 10_dump.sh first" >&2; exit 1; }

echo "==> Restore: pre-data (schemas, tables, extensions)"
pg_restore --no-owner --section=pre-data -v -d "$TARGET_URL" "$DUMP" 2>&1 | tee "$WORKDIR/restore-pre.log" || true

echo "==> Restore: data (rows) — triggers disabled, ${JOBS} parallel jobs"
pg_restore --no-owner --section=data --disable-triggers -j "$JOBS" -v -d "$TARGET_URL" "$DUMP" 2>&1 | tee "$WORKDIR/restore-data.log"

echo "==> Restore: post-data (indexes, constraints, triggers, ACLs, matview refresh)"
pg_restore --no-owner --section=post-data -j "$JOBS" -v -d "$TARGET_URL" "$DUMP" 2>&1 | tee "$WORKDIR/restore-post.log" || true

echo "Restore complete."
