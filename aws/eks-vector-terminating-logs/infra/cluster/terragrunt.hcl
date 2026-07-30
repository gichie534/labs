# EKS cluster + one small managed node group, consuming the network unit's private subnets.
#
# This lab is about observing log collection, not stressing the data plane, so the nodes are small
# (t3.medium) and there are two of them: enough to run the Vector agent DaemonSet on every node, the
# Vector aggregator, and the noisy-terminator workload with room to spare.
#
# Add-ons: vpc-cni + kube-proxy for pod networking, and coredns so the agent can resolve the
# aggregator's cluster-DNS service name (vector-aggregator.vector.svc.cluster.local). No Pod
# Identity is needed — the aggregator sinks to console (stdout), so nothing here talks to an AWS API.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/eks?ref=aws-eks-v0.1.0"
}

dependency "network" {
  config_path = "../network"

  # Let plan/validate run before the network exists (cost-free checks).
  mock_outputs = {
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
  }
}

inputs = {
  name               = "eks-vec-logs"
  kubernetes_version = "1.31"

  subnet_ids = dependency.network.outputs.private_subnet_ids

  node_groups = {
    default = {
      instance_types = [get_env("NODE_INSTANCE_TYPE", "t3.medium")]
      desired_size   = 2
      min_size       = 1
      max_size       = 3
    }
  }

  addons = {
    vpc-cni    = {}
    kube-proxy = {}
    coredns    = {}
  }

  tags = {
    Environment = "lab"
  }
}
