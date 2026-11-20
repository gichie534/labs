# The CRM tables (users, orders) as a BigQuery snapshot. Two jobs, neither of them the agent's:
#   - the source `task seed` exports to CSV and imports into Cloud SQL;
#   - ground truth for the evaluation harness, which computes the expected answers here.
# The agent has NO access to this dataset. Asking it to query bi_crm_snapshot directly is a good way to watch an
# IAM denial surface in the agent's trace.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/bigquery-dataset?ref=gcp-bigquery-dataset-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id    = include.root.locals.project_id
  dataset_id    = include.root.locals.names.crm_snapshot
  location      = include.root.locals.bq_location
  friendly_name = "Business insights - CRM snapshot"
  description   = "TheLook users and orders. Seed source for Cloud SQL and ground truth for evals. Not readable by the agent."

  delete_contents_on_destroy = true
  labels                     = include.root.locals.labels
}
