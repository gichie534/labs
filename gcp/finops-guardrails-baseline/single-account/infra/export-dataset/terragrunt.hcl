# Destination for the Cloud Billing export — the only thing here that can answer "which resource?".
#
# Budgets alert on aggregates. The detailed usage cost export (resource-level line items, labels included) is
# the dataset that answers the follow-up, queryable straight from BigQuery. Like CUR in the AWS lab, it is in
# the baseline because it is effectively not retroactive.
#
# Terraform owns the DATASET only. The export itself cannot be enabled through any API or Terraform resource
# — it is a console setting on the billing account. `task up` therefore ends by printing the console step,
# and `task verify` warns until export tables appear. See docs/adr/0002.
#
# Two settings on this dataset are one-way and decided here on purpose:
#   location   — a multi-region (US by default). Only multi-region datasets get the current AND previous
#                month backfilled when the export is first enabled; a regional one starts from today.
#   expiration — none. Google's own guidance: an export table that expires cannot be backfilled.
#
# Access is additive only (the module ignores drift on `access`). When the export is enabled, Google adds
# billing-export-bigquery@system.gserviceaccount.com as a dataset OWNER; an authoritative access list would
# remove it and the export would stop writing without any error.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/bigquery-dataset?ref=gcp-bigquery-dataset-v0.1.0"
}

dependencies {
  paths = ["../apis"]
}

inputs = {
  project_id    = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  dataset_id    = "billing_export"
  friendly_name = "Cloud Billing export"
  description   = "Detailed usage cost export for the billing account (finops-guardrails-baseline lab). Export is enabled in the console."

  location = get_env("FINOPS_EXPORT_DATASET_LOCATION", "US")

  # Lab dataset: allow `task down` to tear it down even once Google has written tables into it. Turn this
  # off for anything you intend to keep — this data cannot be regenerated.
  delete_contents_on_destroy = true
}
