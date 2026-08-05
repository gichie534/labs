# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws-gcp/rds-to-cloudsql-postgres lab.
#
# This is a CROSS-CLOUD lab: a PostgreSQL RDS instance (AWS, the migration SOURCE) and a Cloud SQL
# for PostgreSQL instance (GCP, the TARGET). So root.hcl generates BOTH provider blocks — aws and
# google — and owns the single GCS remote-state backend every unit shares. Each infra/ unit
# discovers this file via find_in_parent_folders("root.hcl") and never redefines state.
#
# PLACEHOLDERS — fill these in via .env before running (see README / .env.example). They are left as
# obvious sentinels so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # --- GCP (target: Cloud SQL) ---
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")

  # --- AWS (source: RDS) ---
  aws_region = get_env("AWS_REGION", "us-east-1")

  # --- Terraform state (GCS, like the other cross-cloud lab) ---
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
}

# GCP provider — used by the gcp/network and gcp/cloudsql units.
generate "provider_google" {
  path      = "provider_google.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {
      project = "${local.project_id}"
      region  = "${local.region}"
    }
  EOF
}

# AWS provider — used by the aws/network and aws/rds units. Harmless in google-only units (an unused
# provider block costs nothing).
generate "provider_aws" {
  path      = "provider_aws.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"
    }
  EOF
}

remote_state {
  backend = "gcs"
  config = {
    bucket   = local.state_bucket
    prefix   = "${path_relative_to_include()}/terraform.tfstate"
    project  = local.project_id
    location = local.region
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
