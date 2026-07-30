# VPC for the lab. Nodes run in private subnets (roomy /20s — this lab has no IP-pressure angle),
# a single NAT gateway gives them egress to pull the busybox and Vector images. Sourced from the
# modules repo by pinned tag.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  region = include.root.locals.region

  # Two AZs derived from the region (e.g. us-east-1a, us-east-1b). Override with AWS_AZS if your
  # account lacks the first two lexical AZs.
  azs = split(",", get_env("AWS_AZS", "${local.region}a,${local.region}b"))
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=aws-vpc-v0.1.0"
}

inputs = {
  name       = "eks-vec-logs"
  cidr_block = "10.0.0.0/16"

  azs = local.azs

  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.128.0/20", "10.0.144.0/20"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Environment = "lab"
  }
}
