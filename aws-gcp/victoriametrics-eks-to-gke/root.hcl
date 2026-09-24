# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws-gcp/victoriametrics-eks-to-gke lab.
#
# A CROSS-CLOUD lab: an EKS cluster (AWS, migration SOURCE) and a GKE Autopilot cluster (GCP,
# migration TARGET), joined by a BGP-routed IPsec VPN so the migration runs entirely over private
# addressing. So root.hcl generates BOTH provider blocks — aws and google — and owns the single GCS
# remote-state backend every unit shares. Each infra/ unit discovers this file via
# find_in_parent_folders("root.hcl") and never redefines state.
#
# CIDR PLAN (must not overlap — the whole point of the VPN is that both sides are routable):
#   AWS VPC                 10.20.0.0/16   (public 10.20.0.0/20, 10.20.16.0/20
#                                           private 10.20.128.0/20, 10.20.144.0/20; EKS pods take
#                                           private-subnet addresses via the VPC CNI)
#   GCP nodes subnet        10.30.0.0/20
#   GCP pods (secondary)    10.31.0.0/16
#   GCP services (2ndary)   10.32.0.0/20
#   GKE control plane       172.16.0.0/28
#   VPN tunnel inside /30s  169.254.0.0/16 (allocated by AWS)
#
# Values come from the lab's .env (loaded by Task's dotenv) via get_env(...), so a clean checkout
# still runs the cost-free tasks with placeholder values.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # --- GCP (target: GKE + VictoriaMetrics/VictoriaLogs destination) ---
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")

  # --- AWS (source: EKS + VictoriaMetrics/VictoriaLogs origin) ---
  aws_region = get_env("AWS_REGION", "us-east-1")

  # --- Terraform state (GCS, shared by both providers' units) ---
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")

  # --- Shared naming / addressing, referenced by units via include.root.locals ---
  lab            = "vmmig"
  aws_vpc_cidr   = "10.20.0.0/16"
  gcp_nodes_cidr = "10.30.0.0/20"
  gcp_pods_cidr  = "10.31.0.0/16"
  gcp_svcs_cidr  = "10.32.0.0/20"

  # BGP ASNs for the two sides of the VPN. Both are private ASNs; they must differ.
  gcp_bgp_asn     = 65001
  amazon_side_asn = 64512
}

# GCP provider — used by the gcp/* units.
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

# AWS provider — used by the aws/* units. Harmless in google-only units (an unused provider block
# costs nothing).
generate "provider_aws" {
  path      = "provider_aws.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          Lab       = "victoriametrics-eks-to-gke"
          ManagedBy = "terragrunt"
        }
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
