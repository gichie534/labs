-- ============================================================================
-- PARITY CHECK (strict, cross-engine deterministic subset)
-- RDS PostgreSQL (source)  ->  Cloud SQL PostgreSQL (target)
-- ============================================================================
-- Run identically against both databases and diff the two outputs; a ZERO diff means the migration
-- reproduced structure + content exactly. This file deliberately EXCLUDES things that legitimately
-- differ between RDS and Cloud SQL (server version, database size, the managed-service role names in
-- privilege grants, the platform extension set) — those live in migration_verification.sql for
-- manual inspection. What remains here must match byte-for-byte.
--
-- Run with stable, diffable formatting:
--   psql "$URL" -X -A -F $'\t' -P pager=off -v ON_ERROR_STOP=1 -f parity.sql > out
--
-- Timezone/DateStyle are pinned so timestamp text (and thus checksums) are comparable across servers.

SET timezone = 'UTC';
SET DateStyle = 'ISO, YMD';

-- 1. Object inventory — counts of every relation/object type.
SELECT 'tables' AS object_type, count(*) FROM information_schema.tables
        WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'views', count(*) FROM information_schema.views
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'mat_views', count(*) FROM pg_matviews
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'sequences', count(*) FROM information_schema.sequences
        WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'indexes', count(*) FROM pg_indexes
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'functions', count(*) FROM information_schema.routines
        WHERE routine_schema NOT IN ('pg_catalog', 'information_schema')
          AND routine_schema NOT LIKE 'pg\_temp%'
UNION ALL
SELECT 'triggers', count(DISTINCT (event_object_schema, event_object_table, trigger_name))
        FROM information_schema.triggers
        WHERE trigger_schema NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'constraints', count(*) FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY object_type;

-- 2 + 3. Row count + order-independent content checksum per logical table (partitioned tables counted
--         once at the parent). A single changed byte changes the checksum.
CREATE OR REPLACE FUNCTION pg_temp.table_stats()
RETURNS TABLE(table_schema text, table_name text, row_count bigint, checksum numeric)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS s, c.relname AS t
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_temp%'
      AND n.nspname NOT LIKE 'pg_toast%'
    ORDER BY 1, 2
  LOOP
    RETURN QUERY EXECUTE format(
      $q$ SELECT %L::text, %L::text, count(*)::bigint,
                 coalesce(sum(('x' || substr(md5(x.*::text), 1, 16))::bit(64)::bigint::numeric), 0)
          FROM %I.%I AS x $q$,
      r.s, r.t, r.s, r.t);
  END LOOP;
END;
$$;

SELECT * FROM pg_temp.table_stats() ORDER BY table_schema, table_name;

-- 4. Column definitions — types, lengths, nullability, defaults.
SELECT table_schema, table_name, ordinal_position, column_name,
       data_type, character_maximum_length, numeric_precision, numeric_scale,
       is_nullable, column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name, ordinal_position;

-- 5. Constraints — PK / FK / UNIQUE / CHECK definitions.
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

-- 6. Indexes — full definitions.
SELECT schemaname AS schema, tablename AS table_name, indexname AS index_name, indexdef
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, table_name, index_name;

-- 7. Sequences — current values (a high-risk post-migration item: a stale last_value hands out a
--    colliding id on the first insert).
SELECT schemaname AS schema, sequencename AS sequence_name,
       last_value, start_value, increment_by, max_value
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, sequence_name;

-- 8. Routines & triggers — names/signatures.
SELECT routine_schema AS schema, routine_name, routine_type, data_type AS returns
FROM information_schema.routines
WHERE routine_schema NOT IN ('pg_catalog', 'information_schema')
  AND routine_schema NOT LIKE 'pg\_temp%'  -- exclude this file's own pg_temp helper (session-specific name)
ORDER BY schema, routine_name;

SELECT event_object_schema AS schema, event_object_table AS table_name,
       trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE trigger_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, table_name, trigger_name, event_manipulation;

-- 9. Object ownership — the reassignment step must reproduce this exactly (application roles only;
--    the managed-service/admin names are filtered so RDS vs Cloud SQL platform roles don't diff).
SELECT n.nspname AS schema, c.relname AS object_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'S' THEN 'sequence'
                      WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview' END AS kind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'S', 'v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'rds%'
  AND pg_get_userbyid(c.relowner) NOT LIKE 'cloudsql%'
  AND pg_get_userbyid(c.relowner) <> 'postgres'
ORDER BY schema, object_name, kind;
