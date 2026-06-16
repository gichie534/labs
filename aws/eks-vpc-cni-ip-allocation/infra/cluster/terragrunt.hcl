# EKS cluster + one managed node group of LARGE instances, consuming the network unit's private
# subnets.
#
# Large instances are the point: an m5.xlarge supports 3 ENIs x 15 IPs. With the VPC CNI's default
# WARM_ENI_TARGET=1, a node running just a few pods still keeps a whole spare ENI of ~15 secondary
# IPs warm — pure waste. That waste is what tuning WARM_IP_TARGET / MINIMUM_IP_TARGET removes.
#
# This unit owns TWO of the three lab phases:
#   - Phase 1 (baseline): apply with WARM_IP_TARGET / MINIMUM_IP_TARGET UNSET. The vpc-cni addon
#     runs with its default behaviour (WARM_ENI_TARGET=1 — warm a whole spare ENI per node).
#   - Phase 3 (tuned):    re-apply with those env vars SET. Terragrunt rebuilds the vpc-cni addon's
#     configuration_values JSON; the NODES ARE THEN RECYCLED (see the Taskfile / workflow) so fresh
#     nodes boot under the new IP-target math. (Restarting the aws-node daemonset alone does NOT
#     reliably reclaim already-warmed ENIs, because the CNI frees them lazily with cooldowns.)
#
# Phase 2 (scale the node group from 1 -> N) is intentionally NOT done here: the aws/eks module
# sets ignore_changes on the node group's desired_size, so scaling is an `aws eks
# update-nodegroup-config` operation (real CLI, see the Taskfile). That keeps Terragrunt owning
# only declarative config and the CLI owning the imperative scale event.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  # --- Phase knobs (env-var-backed) --------------------------------------------------------------
  # Unset => baseline (phase 1). Set => tuned (phase 3). Empty string means "leave unset".
  warm_ip_target = get_env("WARM_IP_TARGET", "")
  min_ip_target  = get_env("MINIMUM_IP_TARGET", "")

  cni_tuned = local.warm_ip_target != "" || local.min_ip_target != ""

  # Build the env map the VPC CNI understands, dropping any key left empty.
  cni_env = merge(
    local.warm_ip_target != "" ? { WARM_IP_TARGET = local.warm_ip_target } : {},
    local.min_ip_target != "" ? { MINIMUM_IP_TARGET = local.min_ip_target } : {},
  )

  # null => addon keeps its defaults (true baseline). Otherwise a JSON string of {"env": {...}}.
  vpc_cni_config = local.cni_tuned ? jsonencode({ env = local.cni_env }) : null

  # Node group desired size at CREATE time. The module ignores later desired_size drift, so this is
  # only the phase-1 baseline; phase 2 scaling happens via the AWS CLI.
  node_desired = tonumber(get_env("NODE_DESIRED", "1"))
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
  name               = "eks-cni-ip"
  kubernetes_version = "1.31"

  subnet_ids = dependency.network.outputs.private_subnet_ids

  node_groups = {
    default = {
      # Large nodes so a single warmed spare ENI wastes ~15 IPs (3 ENIs x 15 on m5.xlarge).
      # Override with NODE_INSTANCE_TYPE if you want to try another size.
      instance_types = [get_env("NODE_INSTANCE_TYPE", "m5.xlarge")]
      desired_size   = local.node_desired
      min_size       = 1
      # Headroom for phase-2 scale-up via the CLI without re-planning Terraform.
      max_size = 4
    }
  }

  addons = {
    # vpc-cni is the star of the lab. configuration_values flips between null (baseline) and the
    # tuned env JSON (phase 3). OVERWRITE so the addon re-applies the daemonset env on update.
    vpc-cni = {
      configuration_values = local.vpc_cni_config
    }
    kube-proxy             = {}
  }

  tags = {
    Environment = "lab"
  }
}
