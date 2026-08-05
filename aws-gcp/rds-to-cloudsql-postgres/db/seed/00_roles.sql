-- ============================================================================
-- SEED 00 — roles (run against the SOURCE RDS `app` database as the master user)
-- ============================================================================
-- Roles are cluster-global. This mirrors a production shape: NOLOGIN *group* roles that carry
-- privilege, per-service *owner* login roles that own their schema's objects, and a read-only
-- reporting role. Passwords are intentionally NOT set here — the migration sets them on the target
-- at cutover (mirrors pg_dumpall --no-role-passwords, where secrets never travel in the dump).
--
-- Idempotent: safe to re-run.

DO $$
BEGIN
  -- Group (NOLOGIN) roles — privilege bundles, not login identities.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_readonly')  THEN CREATE ROLE app_readonly  NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_readwrite') THEN CREATE ROLE app_readwrite NOLOGIN; END IF;

  -- Per-service owner roles (LOGIN) — each owns one schema's objects.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'svc_sales')   THEN CREATE ROLE svc_sales   LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'svc_billing') THEN CREATE ROLE svc_billing LOGIN; END IF;

  -- Reporting role (LOGIN) — read-only across schemas.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'report_reader') THEN CREATE ROLE report_reader LOGIN; END IF;
END
$$;

-- Membership: service roles can write; the reporting role can read.
GRANT app_readwrite TO svc_sales, svc_billing;
GRANT app_readonly  TO report_reader;

-- Let the master user SET ROLE into the service owners so the rest of the seed creates objects
-- already owned by them (exercising the ownership-migration path). On RDS the master is a member of
-- rds_superuser, so it may grant these.
DO $$
BEGIN
  EXECUTE format('GRANT svc_sales, svc_billing TO %I', current_user);
END
$$;
