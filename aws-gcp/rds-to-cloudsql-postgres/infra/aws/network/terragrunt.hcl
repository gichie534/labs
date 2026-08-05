# AWS VPC that hosts the source RDS PostgreSQL instance. Public subnets only (NAT disabled) because
# the RDS instance is publicly accessible in this lab so an operator can reach it to seed and dump;
# see docs/adr/0002-connectivity.md for why, and how production would keep it private.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=gcp-vpc-vX.Y.Z"
# Using a local relative path while the tag is unreleased (allowed by the tech steering while iterating).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/aws/vpc"
}

locals {
  aws_region = get_env("AWS_REGION", "us-east-1")
}

inputs = {
  name = "rds2cloudsql"

  cidr_block = "10.60.0.0/16"
  azs        = ["${local.aws_region}a", "${local.aws_region}b"]

  public_subnet_cidrs  = ["10.60.0.0/20", "10.60.16.0/20"]
  private_subnet_cidrs = ["10.60.128.0/20", "10.60.144.0/20"]

  # The source DB sits in public subnets and is reached directly; no private egress needed.
  enable_nat_gateway = false

  tags = {
    Lab       = "rds-to-cloudsql-postgres"
    ManagedBy = "terragrunt"
  }
}
