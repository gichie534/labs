#!/usr/bin/env bash
# Seed the lab's data from bigquery-public-data.thelook_ecommerce (synthetic, refreshed daily by Google):
#
#   1. BigQuery bi_analytics       <- events, order_items (last SEED_MONTHS full months + this month), products
#   2. BigQuery bi_crm_snapshot    <- users, orders            (CRM snapshot: seed source + eval ground truth)
#   3. Cloud SQL crm               <- users, orders            (schema.sql, then CSV imports via the seed bucket)
#   4. Cloud SQL grants            <- SELECT for the bi-crm-reader IAM database user (the agent borrows it)
#   5. GCS docs bucket             <- data/docs/*.md           (the business glossary)
#
# Everything is idempotent: re-running replaces the snapshot, recreates the CRM tables and re-applies the grants.
# Cost: a few cents of BigQuery scan; the CSV import takes a few minutes.
set -euo pipefail

: "${GCP_PROJECT:?set GCP_PROJECT}"
MONTHS="${SEED_MONTHS:-6}"
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"

P="$GCP_PROJECT"
SRC="bigquery-public-data.thelook_ecommerce"
ANALYTICS="bi_analytics"
CRM="bi_crm_snapshot"
SEED_BUCKET="$P-bi-seed"
DOCS_BUCKET="$P-bi-docs"
INSTANCE="bi-crm"
DB="crm"
# IAM database login of the bi-crm-reader service account: its email without ".gserviceaccount.com".
READER="bi-crm-reader@$P.iam"
WINDOW="TIMESTAMP(DATE_SUB(DATE_TRUNC(CURRENT_DATE('UTC'), MONTH), INTERVAL $MONTHS MONTH))"

# gcloud's bundled bq warns about its vendored requests/urllib3 versions on every call; the warning is harmless.
export PYTHONWARNINGS="${PYTHONWARNINGS:-ignore}"

# Run a SQL script quietly, but print bq's output if it fails: bq reports query errors on stdout.
bq_sql() {
  local out
  if ! out="$(bq --project_id="$P" --location=US query --use_legacy_sql=false --quiet "$1" 2>&1)"; then
    echo "$out" >&2
    return 1
  fi
}

echo "==> 1/5 Warehouse snapshot ($MONTHS months + month to date) into $P.$ANALYTICS"
bq_sql "
CREATE OR REPLACE TABLE \`$P.$ANALYTICS.events\`
PARTITION BY DATE(created_at) CLUSTER BY user_id, event_type
OPTIONS (description = 'Web events (one row per page/cart/purchase event). user_id is NULL for anonymous visitors.') AS
SELECT id, user_id, sequence_number, session_id, created_at, city, state, browser, traffic_source, uri, event_type
FROM \`$SRC.events\`
WHERE created_at >= $WINDOW AND created_at < CURRENT_TIMESTAMP();

CREATE OR REPLACE TABLE \`$P.$ANALYTICS.order_items\`
PARTITION BY DATE(created_at) CLUSTER BY product_id, status
OPTIONS (description = 'Order line items with status and sale_price (USD). Revenue = non-cancelled, non-returned items.') AS
SELECT id, order_id, user_id, product_id, inventory_item_id, status, created_at, shipped_at, delivered_at, returned_at, sale_price
FROM \`$SRC.order_items\`
WHERE created_at >= $WINDOW AND created_at < CURRENT_TIMESTAMP();

CREATE OR REPLACE TABLE \`$P.$ANALYTICS.products\`
OPTIONS (description = 'Product catalog: category, brand, department, cost and retail price.') AS
SELECT id, cost, category, name, brand, retail_price, department, sku, distribution_center_id
FROM \`$SRC.products\`;
"

echo "==> 2/5 CRM snapshot into $P.$CRM"
# No street address, postal code or coordinates: the agent doesn't need them, so they never leave the source.
bq_sql "
CREATE OR REPLACE TABLE \`$P.$CRM.users\` AS
SELECT id, first_name, last_name, email, age, gender, city, state, country, traffic_source, created_at
FROM \`$SRC.users\`
WHERE created_at < CURRENT_TIMESTAMP();

CREATE OR REPLACE TABLE \`$P.$CRM.orders\` AS
SELECT order_id, user_id, status, created_at, shipped_at, delivered_at, returned_at, num_of_item
FROM \`$SRC.orders\`
WHERE created_at >= $WINDOW AND created_at < CURRENT_TIMESTAMP();
"

echo "==> 3/5 Cloud SQL $INSTANCE/$DB: schema + CSV import"
gcloud storage rm --quiet "gs://$SEED_BUCKET/crm/**" 2>/dev/null || true
ts() { echo "FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%E6S+00', $1)"; }
bq_sql "
EXPORT DATA OPTIONS (uri = 'gs://$SEED_BUCKET/crm/users-*.csv', format = 'CSV', overwrite = true, header = false) AS
SELECT id, first_name, last_name, email, age, gender, city, state, country, traffic_source, $(ts created_at)
FROM \`$P.$CRM.users\`;

EXPORT DATA OPTIONS (uri = 'gs://$SEED_BUCKET/crm/orders-*.csv', format = 'CSV', overwrite = true, header = false) AS
SELECT order_id, user_id, status, $(ts created_at), $(ts shipped_at), $(ts delivered_at), $(ts returned_at), num_of_item
FROM \`$P.$CRM.orders\`;
"
gcloud storage cp --quiet "$LAB_DIR/data/crm/schema.sql" "gs://$SEED_BUCKET/crm/schema.sql"
gcloud sql import sql "$INSTANCE" "gs://$SEED_BUCKET/crm/schema.sql" \
  --project="$P" --database="$DB" --user=postgres --quiet
for table in users orders; do
  for f in $(gcloud storage ls "gs://$SEED_BUCKET/crm/$table-*.csv"); do
    echo "    importing $f"
    gcloud sql import csv "$INSTANCE" "$f" --project="$P" --database="$DB" --table="$table" --user=postgres --quiet
  done
done

echo "==> 4/5 Grants for the IAM database user $READER"
GRANTS="gs://$SEED_BUCKET/crm/grants.sql"
sed -e "s/__USER__/$READER/g" -e "s/__DATABASE__/$DB/g" "$LAB_DIR/data/crm/grants.sql.tmpl" \
  | gcloud storage cp --quiet - "$GRANTS"
gcloud sql import sql "$INSTANCE" "$GRANTS" --project="$P" --database="$DB" --user=postgres --quiet

echo "==> 5/5 Business glossary -> gs://$DOCS_BUCKET/docs/"
gcloud storage cp --quiet "$LAB_DIR"/data/docs/*.md "gs://$DOCS_BUCKET/docs/"

echo
echo "Seeded. Row counts:"
bq --project_id="$P" --location=US query --use_legacy_sql=false --format=pretty "
SELECT 'bi_analytics.events' AS t, COUNT(*) AS n_rows FROM \`$P.$ANALYTICS.events\`
UNION ALL SELECT 'bi_analytics.order_items', COUNT(*) FROM \`$P.$ANALYTICS.order_items\`
UNION ALL SELECT 'bi_analytics.products', COUNT(*) FROM \`$P.$ANALYTICS.products\`
UNION ALL SELECT 'bi_crm_snapshot.users (= Cloud SQL users)', COUNT(*) FROM \`$P.$CRM.users\`
UNION ALL SELECT 'bi_crm_snapshot.orders (= Cloud SQL orders)', COUNT(*) FROM \`$P.$CRM.orders\`"
