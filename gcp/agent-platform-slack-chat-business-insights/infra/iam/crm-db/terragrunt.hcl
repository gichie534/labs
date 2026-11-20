# `gcloud sql import` runs as the Cloud SQL instance's own service account, which must read the seed bucket.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_local}/principal-iam"
}

dependency "crm_db" {
  config_path = "../../cloud-sql/crm"
  mock_outputs = {
    service_account_email_address = "p123456789-abcdef@gcp-sa-cloud-sql.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "seed_bucket" {
  config_path = "../../buckets/seed"
  mock_outputs = {
    name = "mock-seed-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id = include.root.locals.project_id
  member     = "serviceAccount:${dependency.crm_db.outputs.service_account_email_address}"

  bucket_roles = {
    seed = { bucket = dependency.seed_bucket.outputs.name, role = "roles/storage.objectViewer" }
  }
}
