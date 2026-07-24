# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-ingress-iap-playwright lab.
#
# Owns the two things every unit shares: the generated google provider and the GCS remote-state
# backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl") and never
# redefines state.
#
# This lab extends gcp/gke-ingress-iap: same IAP-protected GKE Ingress, but wired so PLAYWRIGHT
# end-to-end tests can authenticate THROUGH IAP from GitHub Actions. The one structural addition is
# that the CI Workload Identity Federation principal is granted Token Creator on the test service
# account (see infra/iap-sa), so CI can mint the IAP bearer JWT the browser tests inject.
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
  # (<project_number>-compute@developer.gserviceaccount.com), which pulls images from the registry,
  # and to build the CI WIF principalSet that impersonates the test SA (see infra/iap-sa).
  # Find it with: gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # GitHub repository (OWNER/REPO) whose Actions workflows may federate into the WIF pool.
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")

  # Workload Identity Federation pool id, shared by the deployer-wif unit (which creates it) and the
  # iap-sa unit (which grants the pool's repo principalSet Token Creator on the test SA). Kept here
  # so the two units cannot drift.
  wif_pool_id = "github-ci-gke-iap-pw"

  # GCS bucket that stores Terraform state for this lab. Must already exist or be auto-created by
  # Terragrunt on first run (the project must allow it).
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # Public hostname the app is served on over HTTPS. This is the apex of a delegated child zone the
  # lab creates (e.g. gke-iap-pw.gcp.example.com). The trailing dot is added where a FQDN is required.
  ingress_domain = get_env("INGRESS_DOMAIN", "REPLACE_WITH_INGRESS_DOMAIN")

  # The Cloud DNS managed-zone RESOURCE NAME (not the domain) of the existing parent zone that the
  # child zone is delegated from. For gke-iap-pw.gcp.example.com the parent is the existing
  # gcp.example.com zone; pass its managed-zone name here. Find it with:
  #   gcloud dns managed-zones list --format='table(name,dnsName)'
  parent_dns_zone = get_env("PARENT_DNS_ZONE", "REPLACE_WITH_PARENT_DNS_ZONE")

  # Project that owns the parent DNS zone. The parent zone lives in a separate bootstrap project, so
  # the NS delegation record must be written there, not in project_id. Defaults to project_id when
  # unset (i.e. parent zone in the same project).
  parent_dns_project = get_env("PARENT_DNS_PROJECT", local.project_id)

  # The human (or group) principal allowed to reach the app THROUGH IAP via the interactive browser
  # sign-in flow, and to impersonate the test service account locally. A fully-qualified IAM member,
  # e.g. "user:you@example.com" or "group:eng@example.com". Must be a Google identity inside this
  # organization.
  iap_member = get_env("IAP_MEMBER", "REPLACE_WITH_user:you@example.com")
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
