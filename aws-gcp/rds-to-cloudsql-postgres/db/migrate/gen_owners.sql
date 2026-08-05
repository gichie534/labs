-- Generate ALTER ... OWNER TO statements from the SOURCE catalog, so the target's objects (restored
-- with --no-owner, hence all owned by the restore user) get their real owners back. Run against the
-- SOURCE with:  psql "$SOURCE_URL" -tAqf gen_owners.sql
--
-- Universal replacement for hand-written ALTER OWNER lists: covers schemas, tables/partitioned
-- parents, views, materialized views, standalone sequences, and functions/procedures owned by
-- application roles (never the managed-service or bootstrap roles).

-- Schemas.
SELECT format('ALTER SCHEMA %I OWNER TO %I;', n.nspname, pg_get_userbyid(n.nspowner))
FROM pg_namespace n
WHERE n.nspname NOT LIKE 'pg\_%'
  AND n.nspname NOT IN ('information_schema', 'public')
  AND pg_get_userbyid(n.nspowner) NOT LIKE 'rds%'
  AND pg_get_userbyid(n.nspowner) NOT LIKE 'cloudsql%'
  AND pg_get_userbyid(n.nspowner) NOT IN ('postgres', current_user)
ORDER BY n.nspname;

-- Tables (incl. partitioned parents), views, materialized views.
SELECT format('ALTER %s %I.%I OWNER TO %I;',
  CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'TABLE'
                 WHEN 'v' THEN 'VIEW'  WHEN 'm' THEN 'MATERIALIZED VIEW' END,
  n.nspname, c.relname, pg_get_userbyid(c.relowner))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm')                -- includes partition children (relkind 'r'):
                                                        -- ALTER on the parent does NOT cascade to them
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'rds%'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'cloudsql%'
  AND pg_get_userbyid(c.relowner) NOT IN ('postgres', current_user)
ORDER BY n.nspname, c.relname;

-- Standalone sequences only (identity/serial-owned sequences follow their table's owner, and can't
-- be reassigned independently — exclude any sequence with an internal/auto dependency on a column).
SELECT format('ALTER SEQUENCE %I.%I OWNER TO %I;', n.nspname, c.relname, pg_get_userbyid(c.relowner))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S'
  AND NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.objid = c.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('i', 'a')
  )
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'rds%'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'cloudsql%'
  AND pg_get_userbyid(c.relowner) NOT IN ('postgres', current_user)
ORDER BY n.nspname, c.relname;

-- Functions and procedures.
SELECT format('ALTER %s %I.%I(%s) OWNER TO %I;',
  CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
  n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), pg_get_userbyid(p.proowner))
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND pg_get_userbyid(p.proowner) NOT LIKE 'rds%'
  AND pg_get_userbyid(p.proowner) NOT LIKE 'cloudsql%'
  AND pg_get_userbyid(p.proowner) NOT IN ('postgres', current_user)
ORDER BY n.nspname, p.proname;
