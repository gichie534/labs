-- ============================================================================
-- SEED 04 — data (run against the SOURCE RDS `app` database)
-- ============================================================================
-- A few thousand synthetic rows: enough to make row-count + content-checksum parity meaningful and
-- to advance the identity sequences (so the migration must carry sequence state), without being
-- large or slow. Inserted under each schema's owner. Safe to re-run (customer email is unique;
-- orders/invoices simply accumulate — re-seeding is not the lab's concern, a fresh RDS is).

SET ROLE svc_sales;

INSERT INTO sales.customer (email, full_name)
SELECT 'user' || g || '@example.com', 'User ' || g
FROM generate_series(1, 500) AS g
ON CONFLICT (email) DO NOTHING;

INSERT INTO sales.orders (customer_id, total_cents, status)
SELECT (1 + floor(random() * 500))::bigint,
       (floor(random() * 100000))::bigint,
       (ARRAY['pending', 'paid', 'refunded'])[1 + floor(random() * 3)::int]
FROM generate_series(1, 2000);

RESET ROLE;

SET ROLE svc_billing;

INSERT INTO billing.invoice (order_id, amount_cents, issued_at)
SELECT (1 + floor(random() * 2000))::bigint,
       (floor(random() * 100000))::bigint,
       (DATE '2024-01-01' + (floor(random() * 700))::int)
FROM generate_series(1, 3000);

-- Advance the standalone sequence so the migration must carry its value.
SELECT setval('billing.invoice_no_seq', 3000);

REFRESH MATERIALIZED VIEW billing.invoice_monthly;

RESET ROLE;
