# Regional GKE Autopilot cluster in the SERVICE project, running on the HOST project's shared subnet.
# The network/subnetwork self-links point at the host VPC; the cluster only works once the Shared
# VPC grants are in place, so it depends on shared-vpc-access.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so an operator/CI can reach the public
# control-plane endpoint. Nodes stay private (egress via the host's Cloud NAT). Acceptable for a
# throwaway lab only. See docs/adr/0001.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.2.0"
}

dependency "project" {
  config_path  = ".."
  mock_outputs = { project_id = "mock-service-project" }
}

dependency "vpc" {
  config_path = "../../host/vpc"
  mock_outputs = {
    network_self_link  = "projects/mock-host/global/networks/shared"
    subnets_self_links = { gke = "projects/mock-host/regions/us-central1/subnetworks/shared-gke" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Ordering only: the networkUser + hostServiceAgentUser grants must exist before the cluster is
# created. No outputs are consumed from this unit.
dependency "shared_vpc_access" {
  config_path                             = "../../host/shared-vpc-access"
  mock_outputs                            = { network_user_members = [] }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name       = "shared-vpc-gke"
  project_id = dependency.project.outputs.project_id
  region     = include.root.locals.region

  network             = dependency.vpc.outputs.network_self_link
  subnetwork          = dependency.vpc.outputs.subnets_self_links["gke"]
  pods_range_name     = "pods"
  services_range_name = "services"

  # Public control-plane endpoint reachable by an operator/CI; nodes remain private. Lab-only.
  enable_private_endpoint = false
  master_authorized_networks = [
    { display_name = "operator-and-world", cidr_block = "0.0.0.0/0" },
  ]

  deletion_protection = false
}
