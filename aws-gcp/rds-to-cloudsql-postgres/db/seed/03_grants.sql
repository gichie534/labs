-- ============================================================================
-- SEED 03 — grants & default privileges (run against the SOURCE RDS `app` database)
-- ============================================================================
-- The privilege graph the migration must reproduce: read-only and read-write group roles across
-- both schemas, plus ALTER DEFAULT PRIVILEGES so future tables inherit the grants. These GRANTs are
-- carried by pg_dump's ACLs (the migration does NOT use --no-acl), since every grantee role is
-- created on the target before the restore.

GRANT USAGE ON SCHEMA sales, billing TO app_readonly, app_readwrite;

GRANT SELECT ON ALL TABLES IN SCHEMA sales, billing TO app_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales, billing TO app_readwrite;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sales, billing TO app_readwrite;

-- Future objects created by each owner inherit the same grants.
ALTER DEFAULT PRIVILEGES FOR ROLE svc_sales IN SCHEMA sales
  GRANT SELECT ON TABLES TO app_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE svc_sales IN SCHEMA sales
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;

ALTER DEFAULT PRIVILEGES FOR ROLE svc_billing IN SCHEMA billing
  GRANT SELECT ON TABLES TO app_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE svc_billing IN SCHEMA billing
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;
