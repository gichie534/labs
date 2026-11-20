-- CRM schema, imported by `task seed` with `gcloud sql import sql` (runs as the postgres user).
-- Idempotent: re-seeding drops and recreates the tables, then the CSVs are imported again.
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
  id             BIGINT PRIMARY KEY,
  first_name     TEXT,
  last_name      TEXT,
  email          TEXT,
  age            INTEGER,
  gender         TEXT,
  city           TEXT,
  state          TEXT,
  country        TEXT,
  traffic_source TEXT,
  created_at     TIMESTAMPTZ
);

CREATE TABLE orders (
  order_id     BIGINT PRIMARY KEY,
  user_id      BIGINT,
  status       TEXT,
  created_at   TIMESTAMPTZ,
  shipped_at   TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  returned_at  TIMESTAMPTZ,
  num_of_item  INTEGER
);

CREATE INDEX users_email_idx ON users (lower(email));
CREATE INDEX orders_user_created_idx ON orders (user_id, created_at);

COMMENT ON TABLE users IS 'TheLook customers. id = user_id in the BigQuery warehouse.';
COMMENT ON TABLE orders IS 'TheLook orders (one row per order). order_id = order_items.order_id in BigQuery.';
