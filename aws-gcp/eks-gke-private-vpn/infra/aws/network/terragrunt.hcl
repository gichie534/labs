# AWS VPC hosting the SOURCE EKS cluster.
#
# Nodes (and, via the VPC CNI, their pods) sit in the PRIVATE subnets, so every address the GKE side
# talks to over the VPN is a private one. Public subnets exist only for the NAT gateway that lets
# nodes pull images.
#
# The private-subnet tags matter more than they look:
#   kubernetes.io/role/internal-elb  - lets the AWS cloud-controller-manager place the INTERNAL
#                                      load balancer that exposes the echo server to the
#                                      GKE side (the module already defaults this, restated here
#                                      because the cluster tag has to be merged in alongside it).
#   kubernetes.io/cluster/<cluster>  - subnet ownership. EKS normally adds this itself; setting it
#                                      explicitly means load balancer subnet discovery does not
#                                      depend on that side effect having happened.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=aws-vpc-v0.1.0"
}

locals {
  lab        = include.root.locals.lab
  aws_region = include.root.locals.aws_region
  vpc_cidr   = include.root.locals.aws_vpc_cidr

  # Kept in sync with infra/aws/cluster by convention; both derive it from the lab prefix.
  cluster_name = "${include.root.locals.lab}-source"
}

inputs = {
  name = local.lab

  cidr_block = local.vpc_cidr
  azs        = ["${local.aws_region}a", "${local.aws_region}b"]

  public_subnet_cidrs  = ["10.20.0.0/20", "10.20.16.0/20"]
  private_subnet_cidrs = ["10.20.128.0/20", "10.20.144.0/20"]

  # Private nodes need egress to pull images and reach the EKS control plane. One shared NAT gateway
  # is enough for a lab and halves the hourly cost of two.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Required by EKS.
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
