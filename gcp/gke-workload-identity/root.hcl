# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-workload-identity lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state
# backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never
# redefines state.
#
# PLACEHOLDERS — fill these in before running (see README / .env.example). They are intentionally
# left as obvious sentinels so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # The GCP project everything is created in.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Region for the regional Autopilot cluster, its VPC subnet, the buckets, and the registry.
  region = get_env("GCP_REGION", "us-central1")

  # Project NUMBER (distinct from project_id). Needed for two things:
  #   - building the GKE node service account email (<num>-compute@developer.gserviceaccount.com)
  #     that pulls images from the registry;
  #   - building the federated KSA principal for direct Workload Identity bindings
  #     (.../workloadIdentityPools/<project_id>.svc.id.goog/subject/ns/<ns>/sa/<ksa>).
  # Find it with: gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # GitHub repository (OWNER/REPO) whose Actions workflows may federate into the GitHub WIF pool
  # used by CI to build/push/deploy. (This is GitHub->GCP federation, separate from the in-cluster
  # KSA->IAM federation the lab demonstrates.)
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")

  # GCS bucket that stores Terraform state for this lab. Create it with `task gke-wi:init-state`.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # The two demo data buckets. Names are derived from the project ID so they're globally unique and
  # need no extra config; the Taskfile derives the same names when seeding and asserting.
  #   - allowed: the KSA is granted roles/storage.objectViewer here (reads succeed).
  #   - denied:  the KSA gets no grant here (reads fail with 403 — the point of the lab).
  bucket_allowed = "${local.project_id}-wif-allowed"
  bucket_denied  = "${local.project_id}-wif-denied"
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
