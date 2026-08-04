# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/gke-argocd-victoriametrics lab.
#
# A GKE Autopilot cluster running Argo CD (direct Google OIDC SSO, no groups) that GitOps-installs
# the VictoriaMetrics observability stack (VMSingle + Grafana, VictoriaLogs + collector) plus a
# sample log/metric generator. Grafana is exposed on a public HTTPS endpoint; DNS records for both
# Argo CD and Grafana are managed dynamically by external-dns.
#
# Owns the generated google provider and the GCS remote-state backend; each infra/ unit discovers
# this file via find_in_parent_folders("root.hcl").
#
# PLACEHOLDERS — fill these in via a local `.env` (see .env.example / README). Sentinels are obvious
# on purpose so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")

  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # Delegated child zone apex; the two public hostnames derive from it. The ONLY place the real
  # domain lives in Terraform — the k8s manifests stay hostname-agnostic (rendered from .env at
  # deploy time), see the ADR.
  base_domain  = get_env("BASE_DOMAIN", "REPLACE_WITH_BASE_DOMAIN")
  argocd_host  = "argocd.${local.base_domain}"
  grafana_host = "grafana.${local.base_domain}"

  parent_dns_zone    = get_env("PARENT_DNS_ZONE", "REPLACE_WITH_PARENT_DNS_ZONE")
  parent_dns_project = get_env("PARENT_DNS_PROJECT", local.project_id)

  # NOTE: secret VALUES are deliberately NOT here. The infra/secrets/* units create empty Secret
  # Manager containers; the values are seeded out-of-band by `task seed-secrets` (from .env / the
  # .pem), so no secret material ever lands in Terraform state. From Secret Manager the GKE add-ons
  # deliver them into the cluster (Grafana via a CSI file mount; the Argo CD OIDC secret + GitHub App
  # key via SecretSync). The two OAuth Web clients and the GitHub App are created manually (no
  # Terraform resource exists for them).
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
