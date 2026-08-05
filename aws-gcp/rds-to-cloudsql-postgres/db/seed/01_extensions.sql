-- ============================================================================
-- SEED 01 — extensions (run against the SOURCE RDS `app` database)
-- ============================================================================
-- Both extensions are on the supported list for RDS PostgreSQL AND Cloud SQL for PostgreSQL, so the
-- migration can recreate them on the target. pgcrypto provides gen_random_uuid(); citext gives a
-- case-insensitive text type used for the customer email.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
