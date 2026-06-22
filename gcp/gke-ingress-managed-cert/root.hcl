# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-ingress-managed-cert lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state
# backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never
# redefines state.
#
# PLACEHOLDERS — fill these in before running anything (see README). They are intentionally left as
# obvious sentinels rather than real values so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # The GCP project everything is created in.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Region for the regional Autopilot cluster, its VPC subnet, and the Artifact Registry repo.
  region = get_env("GCP_REGION", "us-central1")

  # Project number (distinct from project_id) — needed to build the GKE node service account email
  # (<project_number>-compute@developer.gserviceaccount.com), which pulls images from the registry.
  # Find it with: gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # GitHub repository (OWNER/REPO) whose Actions workflows may federate into the WIF pool.
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")

  # GCS bucket that stores Terraform state for this lab. Must already exist or be auto-created by
  # Terragrunt on first run (the project must allow it).
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # Public hostname the app is served on over HTTPS. This is the apex of a delegated child zone the
  # lab creates (e.g. gke-ingress.gcp.richardbatyrov.com). The trailing dot is added where a FQDN is
  # required.
  ingress_domain = get_env("INGRESS_DOMAIN", "REPLACE_WITH_INGRESS_DOMAIN")

  # The Cloud DNS managed-zone RESOURCE NAME (not the domain) of the existing parent zone that the
  # child zone is delegated from. For gke-ingress.gcp.richardbatyrov.com the parent is the existing
  # gcp.richardbatyrov.com zone; pass its managed-zone name here. Find it with:
  #   gcloud dns managed-zones list --format='table(name,dnsName)'
  parent_dns_zone = get_env("PARENT_DNS_ZONE", "REPLACE_WITH_PARENT_DNS_ZONE")

  # Project that owns the parent DNS zone. The parent zone lives in a separate bootstrap project, so
  # the NS delegation record must be written there, not in project_id. Defaults to project_id when
  # unset (i.e. parent zone in the same project).
  parent_dns_project = get_env("PARENT_DNS_PROJECT", local.project_id)
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
