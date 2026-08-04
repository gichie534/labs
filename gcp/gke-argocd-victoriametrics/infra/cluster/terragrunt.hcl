# Regional GKE Autopilot cluster. Consumes the network unit's outputs. Autopilot has the Gateway API
# enabled by default (the gke-l7-global-external-managed Gateway fronting Argo CD + Grafana needs no
# extra cluster config) and always runs with Workload Identity enabled — which every secret path in
# this lab relies on (external-dns to Cloud DNS, and the two Secret Manager add-ons below).
#
# Secret Manager integration (both managed add-ons, no controllers to self-install):
#   - enable_secret_manager_addon: the Secrets Store CSI Driver + GCP provider, for MOUNTING a
#     Secret Manager secret as an in-memory file (Grafana reads its OAuth client secret via $__file).
#   - enable_secret_sync: the SecretSync controller, which MATERIALIZES a Secret Manager secret as a
#     Kubernetes Secret (Argo CD needs real Secrets for its OIDC client secret and the GitHub App
#     key). Requires GKE 1.33+.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so operators can reach the public
# control-plane endpoint for the one-time `kubectl` bootstrap. Lab-only. See docs/adr/0001.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.2.0"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link  = "projects/mock/global/networks/mock"
    subnets_self_links = { nodes = "projects/mock/regions/mock/subnetworks/nodes" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name       = "gke-argocd-victoriametrics"
  project_id = local.project_id
  region     = local.region

  network             = dependency.network.outputs.network_self_link
  subnetwork          = dependency.network.outputs.subnets_self_links["nodes"]
  pods_range_name     = "pods"
  services_range_name = "services"

  enable_private_endpoint = false
  master_authorized_networks = [
    { display_name = "operators-and-world", cidr_block = "0.0.0.0/0" },
  ]

  enable_secret_manager_addon = true
  enable_secret_sync          = true

  deletion_protection = false
}
