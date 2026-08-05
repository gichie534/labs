-- Generate CREATE ROLE + membership statements for APPLICATION roles only, by querying the source
-- cluster's catalog. Run against the SOURCE with:  psql "$SOURCE_URL" -tAqf gen_roles.sql
--
-- Universal replacement for `pg_dumpall --globals-only` + hand-sanitizing: it never emits the
-- managed-service roles (rds*, cloudsql*), the bootstrap `postgres`/master role, or the dangerous
-- attributes (SUPERUSER / REPLICATION / BYPASSRLS) that a managed target rejects. Passwords are set
-- separately at cutover (see gen_passwords.sql).

-- 1) Roles.
SELECT format(
  'DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = %L) THEN CREATE ROLE %I WITH %s %s %s %s; END IF; END $$;',
  r.rolname, r.rolname,
  CASE WHEN r.rolcanlogin   THEN 'LOGIN'      ELSE 'NOLOGIN'      END,
  CASE WHEN r.rolinherit    THEN 'INHERIT'    ELSE 'NOINHERIT'    END,
  CASE WHEN r.rolcreatedb   THEN 'CREATEDB'   ELSE 'NOCREATEDB'   END,
  CASE WHEN r.rolcreaterole THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END
)
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg\_%'
  AND r.rolname NOT LIKE 'rds%'
  AND r.rolname NOT LIKE 'cloudsql%'
  AND r.rolname NOT IN ('postgres', current_user)
ORDER BY r.rolname;

-- 2) Memberships between application roles.
SELECT format('GRANT %I TO %I;', g.rolname, m.rolname)
FROM pg_auth_members am
JOIN pg_roles g ON g.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE g.rolname NOT LIKE 'pg\_%' AND g.rolname NOT LIKE 'rds%' AND g.rolname NOT LIKE 'cloudsql%'
  AND m.rolname NOT LIKE 'pg\_%' AND m.rolname NOT LIKE 'rds%' AND m.rolname NOT LIKE 'cloudsql%'
  AND g.rolname NOT IN ('postgres', current_user)
  AND m.rolname NOT IN ('postgres', current_user)
ORDER BY 1;
