# CI identity (bootstrap): a GitHub Actions OIDC provider + the IAM role the workflow assumes to
# stand the lab up and tear it down — keyless, no static access keys. Sourced from the modules repo
# by pinned tag.
#
# CHICKEN-AND-EGG: this unit creates the very role CI uses, so it cannot be created by CI. Apply it
# ONCE from an admin context (your laptop with admin creds), then set the printed role ARN as the
# repo's AWS_ROLE_ARN variable. It is NOT part of the `up`/`down` phase walk for that reason — see
# the Taskfile's `ci-bootstrap` / `ci-config` tasks.
#
# LAB TRADEOFF: the role is granted broad AWS-managed policies (EKS/EC2/VPC/IAM admin) because the
# workflow creates and destroys a whole cluster. This is a deliberate lab-only choice, the AWS
# analogue of the gke lab's 0.0.0.0/0 caveat. Scope it down with an inline_policy for anything real.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  # GitHub repository (OWNER/REPO) whose Actions workflows may assume the role. The trust policy
  # gates on this exact repo — never widen it.
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/oidc-federation?ref=aws-oidc-federation-v0.1.0"
}

inputs = {
  name_prefix = "eks-cni-ip-"

  provider_url   = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  roles = {
    ci = {
      subjects = ["repo:${local.github_repository}:*"]

      # Broad managed policies: the workflow provisions/destroys VPC + EKS + node groups + addons,
      # and creates the cluster/node IAM roles. No DynamoDB — state locking is S3-native.
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
        "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
        "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
        "arn:aws:iam::aws:policy/IAMFullAccess",
        "arn:aws:iam::aws:policy/AmazonS3FullAccess",
      ]

      # EKS cluster/nodegroup/addon management isn't fully covered by a single managed policy, so add
      # the eks:* surface the workflow needs (create/describe/update/delete cluster + nodegroup +
      # addon, update-nodegroup-config, update-kubeconfig).
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "EksManage"
          Effect   = "Allow"
          Action   = ["eks:*"]
          Resource = "*"
        }]
      })
    }
  }

  tags = {
    Environment = "lab"
  }
}
