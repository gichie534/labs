# The VPC the whole lab runs in: two AZs, public + private subnets. NAT is DISABLED to keep the lab
# cheap — the Fargate tasks run in the PUBLIC subnets with public IPs (assign_public_ip) so they can
# pull images from ECR and reach AWS APIs via the internet gateway, with their security group locked
# down to the ALB. See the ADR for the public-subnet-vs-NAT tradeoff.
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
  name       = "ecs-fargate-https"
  cidr_block = "10.20.0.0/16"
  azs        = local.azs

  public_subnet_cidrs  = ["10.20.0.0/20", "10.20.16.0/20"]
  private_subnet_cidrs = ["10.20.128.0/20", "10.20.144.0/20"]

  # Tasks run in public subnets with public IPs, so no NAT gateway is needed.
  enable_nat_gateway = false

  tags = {
    Environment = "lab"
  }
}
