# The IAM identity for the demo instance — the whole point of the lab.
#
# It wires up the minimal chain that lets an EC2 instance call AWS APIs with no static credentials:
#   EC2 --assume--> role --(policies)--> permissions, handed to the instance via an instance profile.
#
# Two grants, deliberately minimal:
#   - AmazonSSMManagedInstanceCore (managed) — lets you reach the box via SSM Session Manager, so the
#     lab needs no SSH key and no inbound port 22.
#   - s3:ListAllMyBuckets (inline)          — exactly what `aws s3 ls` calls, and nothing more. This
#     is the least-privilege grant the lab is demonstrating.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

inputs = {
  name = "ec2-instance-profile-lab"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # Least privilege: list bucket names only — precisely what `aws s3 ls` needs.
  inline_policies = {
    s3-list = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "ListAllMyBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      }]
    })
  }

  tags = {
    Environment = "lab"
  }
}
