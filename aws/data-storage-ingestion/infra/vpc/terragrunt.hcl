# The lab's dedicated VPC. Three AZs, each with a public and a private subnet.
#
# THREE AZs, not the usual two: Redshift Serverless refuses to create a workgroup with fewer than
# three subnets spanning three availability zones.
#
# NAT is deliberately DISABLED. Nothing in this lab needs outbound internet from a private subnet —
# the workgroup is reached through the Redshift Data API (a regional AWS endpoint, not a network path
# into the VPC), and COPY traffic to S3 travels over the AWS network because enhanced VPC routing is
# left off. Skipping NAT removes the largest hourly cost in the lab.
#
# /20 private subnets give the workgroup plenty of free addresses; Redshift's IP requirement scales
# with base capacity and a /24 is the documented minimum.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=aws-vpc-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

inputs = {
  name       = "streaming-vs-batch-ingestion"
  cidr_block = "10.0.0.0/16"

  azs                  = dependency.lookups.outputs.azs
  public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnet_cidrs = ["10.0.128.0/20", "10.0.144.0/20", "10.0.160.0/20"]

  # No NAT: nothing needs outbound internet from the private subnets.
  enable_nat_gateway = false

  # Not an EKS lab — drop the default kubernetes.io subnet tags.
  public_subnet_tags  = {}
  private_subnet_tags = {}

  tags = {
    Environment = "lab"
  }
}
