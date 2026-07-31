# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-argocd lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state
# backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never
# redefines state.
#
# PLACEHOLDERS — fill these in via a local `.env` (see .env.example / README). They are intentionally
# left as obvious sentinels rather than real values so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # The GCP project everything is created in.
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # Region for the regional Autopilot cluster, its VPC subnet, and the reserved Gateway IP is global.
  region = get_env("GCP_REGION", "us-central1")

  # GCS bucket that stores Terraform state for this lab. Must already exist or be auto-created by
  # Terragrunt on first run (create it with `task argocd:init-state`).
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # Public hostname Argo CD is served on over HTTPS. This is the apex of a delegated child zone the
  # lab creates (e.g. argocd.gcp.example.com). It is the ONLY place the real domain lives — the
  # Kubernetes manifests under deploy/ are deliberately hostname-agnostic, so the domain never leaks
  # into committed GitOps files. The trailing dot is added where a FQDN is required.
  argocd_domain = get_env("ARGOCD_DOMAIN", "REPLACE_WITH_ARGOCD_DOMAIN")

  # The Cloud DNS managed-zone RESOURCE NAME (not the domain) of the existing parent zone that the
  # child zone is delegated from. For argocd.gcp.example.com the parent is the existing
  # gcp.example.com zone; pass its managed-zone name here. Find it with:
  #   gcloud dns managed-zones list --format='table(name,dnsName)'
  parent_dns_zone = get_env("PARENT_DNS_ZONE", "REPLACE_WITH_PARENT_DNS_ZONE")

  # Project that owns the parent DNS zone. The parent zone often lives in a separate bootstrap
  # project, so the NS delegation record must be written there, not in project_id. Defaults to
  # project_id when unset (i.e. parent zone in the same project).
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
