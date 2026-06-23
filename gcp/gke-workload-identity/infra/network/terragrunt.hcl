# VPC for the cluster: one GKE-ready subnet with secondary ranges for Pods and Services, plus
# Cloud NAT so the private Autopilot nodes get egress. Sourced from the modules repo by pinned tag.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/vpc?ref=gcp-vpc-v0.1.0"
}

inputs = {
  name       = "gke-workload-identity"
  project_id = local.project_id

  subnets = [
    {
      name                = "nodes"
      region              = local.region
      ip_cidr_range       = "10.0.0.0/20"
      pods_cidr_range     = "10.16.0.0/14"
      services_cidr_range = "10.20.0.0/20"
      pods_range_name     = "pods"
      services_range_name = "services"
    },
  ]

  private_service_access = false
}
