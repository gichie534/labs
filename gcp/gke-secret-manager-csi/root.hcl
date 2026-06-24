# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-secret-manager-csi lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state
# backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never
# redefines state.
#
# PLACEHOLDERS — fill these in via .env (see .env.example). They are intentionally left as obvious
# sentinels so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # The GCP project everything is created in.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Region for the regional Autopilot cluster and its VPC subnet. Secrets are global by default
  # (auto replication), so location only matters for the cluster and network.
  region = get_env("GCP_REGION", "us-central1")

  # Project NUMBER (distinct from project_id). Needed to build the federated KSA principal for
  # direct Workload Identity bindings:
  #   .../workloadIdentityPools/<project_id>.svc.id.goog/subject/ns/<ns>/sa/<ksa>
  # Find it with: gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # GCS bucket that stores Terraform state for this lab. Create it with `task csi:init-state`.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {
      project = "${local.project_id}"
      region  = "${local.region}"
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
