# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-argocd-sso-google-groups lab.
#
# This is the base gke-argocd lab plus Google Workspace SSO (Argo CD's bundled Dex, Google connector)
# and multi-tenant RBAC. Owns the generated google provider and the GCS remote-state backend; each
# infra/ unit discovers this file via find_in_parent_folders("root.hcl").
#
# PLACEHOLDERS — fill these in via a local `.env` (see .env.example / README). Sentinels are obvious
# on purpose so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")

  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # Public hostname Argo CD is served on over HTTPS (apex of a delegated child zone). The ONLY place
  # the real domain lives in Terraform — see the base lab for why the k8s manifests stay
  # hostname-agnostic.
  argocd_domain = get_env("ARGOCD_DOMAIN", "REPLACE_WITH_ARGOCD_DOMAIN")

  parent_dns_zone    = get_env("PARENT_DNS_ZONE", "REPLACE_WITH_PARENT_DNS_ZONE")
  parent_dns_project = get_env("PARENT_DNS_PROJECT", local.project_id)

  # OAuth 2.0 Web client secret for Dex's Google connector. The client itself is created MANUALLY in
  # the Cloud console (Google has no Terraform resource for generic web OAuth clients); its secret is
  # seeded here from .env and stored in Secret Manager by the sso-secrets unit. Sensitive.
  oauth_client_secret = get_env("OAUTH_CLIENT_SECRET", "REPLACE_WITH_OAUTH_CLIENT_SECRET")
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
