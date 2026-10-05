# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/finops-guardrails-baseline/single-account lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state backend. Each
# infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never redefines state.
#
# WHY THE PROVIDER SETS A QUOTA PROJECT: the Cloud Billing Budget API refuses end-user credentials unless the
# request names a quota project. `billing_project` + `user_project_override = true` make the provider send
# one (this project) on every call. Without them `gcloud auth application-default login` + `task up` fails on
# the first budget with a 403 that talks about credentials, not about a missing setting.
#
# WHY THERE IS NO REGION KNOB FOR THE GUARDRAILS: budgets live on the billing account and notification
# channels and Pub/Sub topics are global. GCP_REGION only places the state bucket. The one location that
# matters is the export dataset's, and it is a multi-region on purpose (docs/adr/0002).
#
# PLACEHOLDERS — fill these in via .env (see .env.example).
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # The project the guardrails watch, and the one that hosts the alert channel, topic and export dataset.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Only used for the state bucket. Nothing else in this lab is regional.
  region = get_env("GCP_REGION", "us-central1")

  # GCS bucket that stores Terraform state for this lab. Create it with `task init-state`.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {
      project = "${local.project_id}"
      region  = "${local.region}"

      # Quota project for APIs that reject end-user credentials without one (Billing Budgets). See above.
      billing_project       = "${local.project_id}"
      user_project_override = true

      # Stamped on every labelable resource. These are what the billing export's labels column — and the
      # "untagged" query in `task show-spend` — key on (docs/adr/0004).
      default_labels = {
        lab        = "finops-guardrails-baseline-single-account"
        managed-by = "terragrunt"
      }
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
