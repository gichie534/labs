# Regional GKE Autopilot cluster. Consumes the network unit's outputs rather than duplicating any
# network config. Autopilot always has Workload Identity enabled (the <project>.svc.id.goog pool),
# which is the federation primitive this lab demonstrates.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so the GitHub-hosted runner (unpredictable
# egress IPs) can reach the public control-plane endpoint to run kubectl/helm. Lab-only. See ADR.

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
  name       = "gke-workload-identity"
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

  # The lab is meant to be torn down with `task gke-wi:down`.
  deletion_protection = false
}
