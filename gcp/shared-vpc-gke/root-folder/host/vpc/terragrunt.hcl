# The shared VPC network in the HOST project: one GKE-ready subnet with secondary ranges for Pods
# and Services, plus Cloud NAT for private-node egress. Consumed by the service project's cluster
# across the Shared VPC. Sourced from the modules repo by pinned tag.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/vpc?ref=gcp-vpc-v0.1.0"
}

dependency "project" {
  config_path  = ".."
  mock_outputs = { project_id = "mock-host-project" }
}

inputs = {
  name       = "shared"
  project_id = dependency.project.outputs.project_id

  subnets = [
    {
      name                = "gke"
      region              = include.root.locals.region
      ip_cidr_range       = "10.0.0.0/20"
      pods_cidr_range     = "10.16.0.0/14"
      services_cidr_range = "10.20.0.0/20"
      pods_range_name     = "pods"
      services_range_name = "services"
    },
  ]

  # No Cloud SQL / PSA in this lab; NAT stays on for private node egress.
  private_service_access = false
}
