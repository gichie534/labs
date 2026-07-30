# The Shared VPC IAM unit: grants the SERVICE project's GKE service agents access to the HOST
# subnet (roles/compute.networkUser, scoped to the subnet) and lets the GKE service agent manage
# the cluster's networking in the host project (roles/container.hostServiceAgentUser).
#
# Depends on the host project (subnet owner), the host VPC (the subnet name), and the service
# project (its NUMBER, and — critically — its Container API being enabled so the GKE service agent
# exists before these bindings are created).
#
# Sourced from the local infrastructure-catalog checkout while gcp/shared-vpc-iam is unreleased —
# TODO: switch to git::...//modules/gcp/shared-vpc-iam?ref=gcp-shared-vpc-iam-v0.1.0.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_modules}/gcp/shared-vpc-iam"
}

dependency "host_project" {
  config_path  = ".."
  mock_outputs = { project_id = "mock-host-project" }
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    subnets = { gke = { name = "shared-gke" } }
  }
}

dependency "service_project" {
  config_path  = "../../service"
  mock_outputs = { project_number = "000000000000" }
}

inputs = {
  host_project_id        = dependency.host_project.outputs.project_id
  service_project_number = dependency.service_project.outputs.project_number
  region                 = include.root.locals.region
  subnetwork             = dependency.vpc.outputs.subnets["gke"].name
}
