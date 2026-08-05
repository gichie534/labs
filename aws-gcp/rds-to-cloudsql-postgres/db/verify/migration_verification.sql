-- ============================================================================
-- POSTGRESQL MIGRATION VERIFICATION (full, for manual inspection)
-- RDS PostgreSQL (source)  ->  Cloud SQL PostgreSQL (target)
-- ============================================================================
--
-- USAGE
--   Run this whole file against BOTH databases and diff the outputs:
--
--     psql "$SOURCE_URL" -A -F $'\t' -P pager=off -f migration_verification.sql > source.out
--     psql "$TARGET_URL" -A -F $'\t' -P pager=off -f migration_verification.sql > target.out
--     diff source.out target.out
--
--   `task verify` runs the strict, always-zero-on-success subset (parity.sql). This fuller file adds
--   sections that legitimately DIFFER between RDS and Cloud SQL — server version, database size, the
--   platform extension set, and privilege grants naming managed-service roles — so read its diff with
--   judgement rather than as a hard pass/fail. Run during a quiet window (or after cutover with writes
--   stopped) so the two snapshots are comparable.
-- ============================================================================

SET timezone = 'UTC';
SET DateStyle = 'ISO, YMD';

-- 0. Environment fingerprint (informational — versions/sizes differ between RDS and Cloud SQL).
SELECT version() AS server_version;
SELECT current_database() AS database_name,
       pg_size_pretty(pg_database_size(current_database())) AS database_size;

-- 1. Object inventory.
SELECT 'tables' AS object_type, count(*) FROM information_schema.tables
        WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'views', count(*) FROM information_schema.views
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'mat_views', count(*) FROM pg_matviews
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'sequences', count(*) FROM information_schema.sequences
        WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'indexes', count(*) FROM pg_indexes
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'functions', count(*) FROM information_schema.routines
        WHERE routine_schema NOT IN ('pg_catalog', 'information_schema')
          AND routine_schema NOT LIKE 'pg\_temp%'
UNION ALL SELECT 'triggers', count(DISTINCT (event_object_schema, event_object_table, trigger_name))
        FROM information_schema.triggers
        WHERE trigger_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL SELECT 'constraints', count(*) FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY object_type;

-- 2 + 3. Row count + content checksum per logical table.
CREATE OR REPLACE FUNCTION pg_temp.table_stats()
RETURNS TABLE(table_schema text, table_name text, row_count bigint, checksum numeric)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS s, c.relname AS t
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%'
    ORDER BY 1, 2
  LOOP
    RETURN QUERY EXECUTE format(
      $q$ SELECT %L::text, %L::text, count(*)::bigint,
                 coalesce(sum(('x' || substr(md5(x.*::text), 1, 16))::bit(64)::bigint::numeric), 0)
          FROM %I.%I AS x $q$, r.s, r.t, r.s, r.t);
  END LOOP;
END;
$$;
SELECT * FROM pg_temp.table_stats() ORDER BY table_schema, table_name;

-- 4. Column definitions.
SELECT table_schema, table_name, ordinal_position, column_name,
       data_type, character_maximum_length, numeric_precision, numeric_scale,
       is_nullable, column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name, ordinal_position;

-- 5. Constraints.
SELECT n.nspname AS schema, t.relname AS table_name, c.conname AS constraint_name,
       CASE c.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                      WHEN 'u' THEN 'UNIQUE' WHEN 'c' THEN 'CHECK'
                      WHEN 'x' THEN 'EXCLUDE' ELSE c.contype::text END AS constraint_type,
       pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, table_name, constraint_type, constraint_name;

-- 6. Indexes.
SELECT schemaname AS schema, tablename AS table_name, indexname AS index_name, indexdef
FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, table_name, index_name;

-- 7. Sequences + a target-side collision check (any row returned = a sequence that will hand out a
--    colliding id).
SELECT schemaname AS schema, sequencename AS sequence_name,
       last_value, start_value, increment_by, max_value
FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, sequence_name;

-- 8. Extensions (RDS and Cloud SQL ship different sets — confirm every extension your APP uses
--    exists on the target).
SELECT e.extname AS extension, e.extversion AS version, n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;

-- 9. Table privileges (ignore rows for platform superuser roles, which differ by engine).
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY grantee, table_schema, table_name, privilege_type;

-- 10. Object ownership (application roles only).
SELECT n.nspname AS schema, c.relname AS object_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'S' THEN 'sequence'
                      WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview' END AS kind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'S', 'v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY schema, object_name, kind;
