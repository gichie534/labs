# Staging area for `task seed`: CSV exports of the CRM snapshot and the SQL files that Cloud SQL imports.
# Only the Cloud SQL instance's service account (iam/crm-db unit) and the operator read it. The agent
# has no access: the CRM data must reach the agent through Cloud SQL and its read-only user, nowhere else.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/gcs?ref=gcp-gcs-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id    = include.root.locals.project_id
  name          = include.root.locals.names.seed_bucket
  location      = include.root.locals.region
  force_destroy = true
  labels        = include.root.locals.labels
}
