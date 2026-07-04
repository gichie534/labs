# Security group for the VPC-attached Lambda's ENIs. Egress-only: the function needs to reach OUT to
# the EC2 instance on the app port, but nothing needs to reach the function. The module's default
# egress rule (allow-all) covers the outbound path; we declare no ingress.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/security-group?ref=aws-security-group-v0.1.0"
}

dependency "vpc" {
  config_path = "../../vpc"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
}

inputs = {
  name        = "lambda-vpc-private-access-lambda"
  vpc_id      = dependency.vpc.outputs.vpc_id
  description = "VPC-attached Lambda ENIs: egress only (reach the EC2 app port)."

  # No ingress. egress_rules defaults to allow-all.

  tags = {
    Environment = "lab"
  }
}
