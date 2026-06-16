# VPC for the lab. Uses modest /25 private subnets (123 usable IPs each) so the VPC-CNI's per-node
# ENI warming visibly drains the subnet's AvailableIpAddressCount — the point of this lab — while
# still leaving headroom for 3 large untuned nodes (each warming ~30 IPs) before the tuning phase.
# With default /20 subnets the IP burn would be invisible. Sourced from the modules repo by pinned tag.

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
  name       = "eks-cni-ip"
  cidr_block = "10.0.0.0/16"

  azs = local.azs

  # Public subnets are roomy (NAT + any LB). Private subnets are kept modest on purpose: /25 = 123
  # usable IPs each, so warmed ENIs of secondary IPs visibly drain the subnet, but 3 large untuned
  # nodes still fit before the tuning phase reclaims the waste.
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.128.0/25", "10.0.128.128/25"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Environment = "lab"
  }
}
