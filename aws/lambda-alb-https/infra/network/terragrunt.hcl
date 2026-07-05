# The VPC the ALB lives in. An ALB requires subnets in at least two AZs, so this lab needs a VPC even
# though the Lambda itself is NOT attached to it — the ALB invokes the function through the Lambda
# service, not over the network. NAT is DISABLED (nothing needs private egress here) to keep the lab
# cheap. Only the public subnets are used (for the internet-facing ALB).
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=aws-vpc-v0.1.0"
}

locals {
  region = get_env("AWS_REGION", "us-east-1")
  azs    = [format("%sa", local.region), format("%sb", local.region)]
}

inputs = {
  name       = "lambda-alb-https"
  cidr_block = "10.30.0.0/16"
  azs        = local.azs

  public_subnet_cidrs  = ["10.30.0.0/20", "10.30.16.0/20"]
  private_subnet_cidrs = ["10.30.128.0/20", "10.30.144.0/20"]

  # Nothing runs in private subnets here, so no NAT gateway is needed.
  enable_nat_gateway = false

  tags = {
    Environment = "lab"
  }
}
