# Regional GKE Autopilot cluster. Consumes the network unit's outputs. Autopilot has the Gateway API
# enabled by default, so the gke-l7-global-external-managed Gateway fronting Argo CD needs no extra
# cluster config.
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
  name       = "gke-argocd-sso-google-groups"
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

  deletion_protection = false
}
