# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws-gcp/gke-sqs-federation lab.
#
# This is a CROSS-CLOUD lab: a GKE cluster (GCP) and an SQS queue (AWS), with GKE pods authenticating
# to AWS keylessly via OIDC web identity federation. So root.hcl generates BOTH provider blocks —
# google and aws — and owns the single GCS remote-state backend every unit shares. Each infra/ unit
# discovers this file via find_in_parent_folders("root.hcl") and never redefines state.
#
# PLACEHOLDERS — fill these in via .env before running (see README / .env.example). They are left as
# obvious sentinels so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # --- GCP ---
  # The GCP project the VPC and GKE cluster are created in.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Region for the regional Autopilot cluster and its VPC subnet.
  region = get_env("GCP_REGION", "us-central1")

  # Project NUMBER (distinct from project_id). Used to build the GKE node service account email
  # (<num>-compute@developer.gserviceaccount.com) that pulls images from Artifact Registry.
  # gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # --- AWS ---
  # Region the SQS queue and IAM resources live in.
  aws_region = get_env("AWS_REGION", "us-east-1")

  # --- Terraform state ---
  # GCS bucket that stores Terraform state for this lab. Create it with `task gke-sqs:init-state`.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # --- Shared identity wiring (must match across the federation unit and the Helm chart) ---
  # The Kubernetes namespace and the two service accounts the workloads run as. The federation unit
  # scopes each AWS IAM role's trust policy to exactly one of these KSA subjects, and the Helm chart
  # creates KSAs with these names. Keep all three in lockstep.
  k8s_namespace = "sqsdemo"
  writer_ksa    = "writer"
  reader_ksa    = "reader"
}

# GCP provider — used by the network, cluster, and registry units.
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

# AWS provider — used by the queue and federation units. Harmless in google-only units (Terragrunt
# generates it per unit, but an unused provider block costs nothing).
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
