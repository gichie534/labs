# Lab-local security unit. Sourced from a local path (not the modules repo) because it's lab-specific
# glue — one security group for the app instances — not reusable infrastructure.
#
# It exists to break the ALB<->instance ordering problem: the instances need a security group before
# they launch, and the ALB needs the instance IDs to register as targets. By giving the app SG a
# static rule (port 80 from the VPC CIDR) rather than referencing the ALB's SG, the units form a
# clean line: lookups -> security -> app-a/app-b -> alb.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    vpc_id         = "vpc-mock"
    vpc_cidr_block = "10.0.0.0/16"
  }
}

inputs = {
  name           = "alb-routing-lab-app"
  vpc_id         = dependency.lookups.outputs.vpc_id
  vpc_cidr_block = dependency.lookups.outputs.vpc_cidr_block
}
