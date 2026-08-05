#!/usr/bin/env bash
# Step 2 — create the application roles on the target BEFORE the restore, so the dump's ownership
# and ACL entries resolve. Then grant those roles to the restore user (the target admin) so it can
# reassign ownership in step 4 (a managed-service admin is not a real superuser, so it can only set
# ownership to roles it is a member of).
#
# Env: TARGET_URL (target `app` DB, connected as the admin/postgres user), WORKDIR.
set -euo pipefail

: "${TARGET_URL:?set TARGET_URL to the target app-database libpq URL (as the admin user)}"
WORKDIR="${WORKDIR:-./_migration}"
ROLES="$WORKDIR/roles.gen.sql"
[ -f "$ROLES" ] || { echo "missing $ROLES — run 10_dump.sh first" >&2; exit 1; }

echo "==> Creating application roles on the target"
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 -f "$ROLES"

echo "==> Granting application roles to the restore/admin user (so it can reassign ownership)"
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT rolname FROM pg_roles
    WHERE rolname NOT LIKE 'pg\_%'
      AND rolname NOT LIKE 'rds%'
      AND rolname NOT LIKE 'cloudsql%'
      AND rolname NOT IN ('postgres', current_user)
  LOOP
    EXECUTE format('GRANT %I TO %I', r.rolname, current_user);
  END LOOP;
END
$$;
SQL

echo "Roles loaded."
