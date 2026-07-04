# The lab's dedicated VPC: two AZs, each with a public and a private subnet.
#
# NAT is deliberately DISABLED. The whole point of the lab is Lambda reaching a private EC2 instance
# over the VPC's internal network — that traffic never leaves the VPC, so no NAT gateway (and no
# hourly NAT cost) is needed. The private subnets get an isolated route table with no default route,
# which is exactly the "private, no internet egress" posture we want to demonstrate.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=aws-vpc-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    ami_id = "ami-00000000000000000"
    azs    = ["us-east-1a", "us-east-1b"]
  }
}

inputs = {
  name       = "lambda-vpc-private-access"
  cidr_block = "10.0.0.0/16"

  azs                  = dependency.lookups.outputs.azs
  public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20"]
  private_subnet_cidrs = ["10.0.128.0/20", "10.0.144.0/20"]

  # No NAT: private subnets stay isolated; Lambda->EC2 traffic is internal to the VPC.
  enable_nat_gateway = false

  # Not an EKS lab — drop the default kubernetes.io subnet tags.
  public_subnet_tags  = {}
  private_subnet_tags = {}

  tags = {
    Environment = "lab"
  }
}
