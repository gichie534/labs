# The VPC the gallery's ECS service runs in: two AZs, public + private subnets. NAT is DISABLED to
# keep the lab cheap — the Fargate tasks run in the PUBLIC subnets with public IPs (assign_public_ip)
# so they can pull images from ECR and reach AWS APIs via the internet gateway, with their security
# group locked down to the ALB. The image-pipeline Lambdas run outside any VPC, so they need nothing
# here. See the ADR for the public-subnet-vs-NAT tradeoff.
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
  name       = "serverless-ai-gallery"
  cidr_block = "10.30.0.0/16"
  azs        = local.azs

  public_subnet_cidrs  = ["10.30.0.0/20", "10.30.16.0/20"]
  private_subnet_cidrs = ["10.30.128.0/20", "10.30.144.0/20"]

  # Tasks run in public subnets with public IPs, so no NAT gateway is needed.
  enable_nat_gateway = false

  tags = {
    Environment = "lab"
  }
}
