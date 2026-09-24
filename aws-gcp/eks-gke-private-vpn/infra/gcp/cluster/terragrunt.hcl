# The GKE Autopilot cluster: the other end of the private cross-cloud path, and where the connectivity
# test runs. It reaches the EKS echo server over the VPN using private addressing only.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so your kubectl reaches the control plane from
# anywhere. Only the CONTROL PLANE is public; the workload path is private-only.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.2.1"
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link  = "projects/mock/global/networks/mock"
    subnets_self_links = { nodes = "projects/mock/regions/mock/subnetworks/nodes" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name       = "${include.root.locals.lab}-target"
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

  # Must not overlap the VPC ranges or anything advertised over the VPN.
  master_ipv4_cidr_block = "172.16.0.0/28"

  deletion_protection = false

  resource_labels = {
    lab  = "eks-gke-private-vpn"
    role = "vpn-connectivity"
  }
}
