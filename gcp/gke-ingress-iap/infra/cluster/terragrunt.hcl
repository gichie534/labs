# Regional GKE Autopilot cluster. Consumes the network unit's outputs (network/subnet self links
# and secondary range names) rather than duplicating any network config.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so the GitHub-hosted runner (which has
# unpredictable egress IPs) can reach the public control-plane endpoint to run `helm`. This widens
# control-plane exposure and is acceptable only for a throwaway lab. See docs/adr/0001.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.1.0"
}

dependency "network" {
  config_path = "../network"

  # Lets `plan`/`validate` run before the network exists (cost-free checks).
  mock_outputs = {
    network_self_link  = "projects/mock/global/networks/mock"
    subnets_self_links = { nodes = "projects/mock/regions/mock/subnetworks/nodes" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name       = "gke-ingress-iap"
  project_id = local.project_id
  region     = local.region

  network             = dependency.network.outputs.network_self_link
  subnetwork          = dependency.network.outputs.subnets_self_links["nodes"]
  pods_range_name     = "pods"
  services_range_name = "services"

  # Public endpoint reachable by CI; nodes remain private. Lab-only — see tradeoff note above.
  enable_private_endpoint = false
  master_authorized_networks = [
    { display_name = "ci-and-world", cidr_block = "0.0.0.0/0" },
  ]

  # The lab is meant to be torn down with `task gke-iap:down`.
  deletion_protection = false
}
