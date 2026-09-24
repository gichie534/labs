# The EKS cluster: one end of the private cross-cloud path. It runs a trivial echo server and nothing
# else — a connectivity lab should only ever fail for network reasons.
#
# Nodes run in the private subnets, so the addresses the GKE side reaches over the VPN come from the
# VPC's own private ranges (the VPC CNI gives pods real VPC addresses).
#
# LAB TRADEOFF: endpoint_public_access_cidrs is 0.0.0.0/0 so your kubectl reaches the API server from
# anywhere. Only the CONTROL PLANE is public — the workload path between the clusters has no public
# listener at all. Narrow this for anything longer-lived.
# See docs/adr/0001-cross-cloud-vpn-topology.md.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/eks?ref=aws-eks-v0.2.0"
}

locals {
  cluster_name = "${include.root.locals.lab}-source"

  # An echo server and nothing else, so the nodes can be small.
  node_instance_type = get_env("NODE_INSTANCE_TYPE", "t3.small")
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
  }
  # apply/destroy included so `run --all` can parse inputs when the dependency's outputs aren't ready
  # yet or are already gone (teardown re-run); mocks are transient and never affect real resources.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name               = local.cluster_name
  kubernetes_version = "1.36"

  subnet_ids = dependency.network.outputs.private_subnet_ids

  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = ["0.0.0.0/0"]

  node_groups = {
    default = {
      instance_types = [local.node_instance_type]
      desired_size   = 2
      min_size       = 2
      max_size       = 3
      disk_size      = 50
    }
  }

  addons = {
    vpc-cni    = {}
    coredns    = {}
    kube-proxy = {}
  }

  tags = {
    Role = "vpn-connectivity"
  }
}
