# IAM identity for the ALLOWED instance.
#
# RBAC layer (identical to the denied role): an inline least-privilege policy granting s3:ListBucket
# + s3:GetObject on the demo bucket, plus AmazonSSMManagedInstanceCore so we can drive the proof
# over SSM. On RBAC alone, BOTH roles can read the bucket.
#
# ABAC layer (the difference): this role carries the tag `project = abac-lab`. AWS surfaces an IAM
# role's tags as aws:PrincipalTag/* on the instance's assumed-role session, and the demo bucket
# policy allows access only when aws:PrincipalTag/project == "abac-lab". So only THIS role clears the
# bucket policy — that's the whole point of the lab.
#
# The IAM role/profile itself is sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

locals {
  # Demo bucket the ABAC policy protects (from .env). The RBAC grant references it by ARN.
  bucket     = get_env("ABAC_BUCKET", "ec2-abac-s3-lab")
  bucket_arn = "arn:aws:s3:::${local.bucket}"
}

inputs = {
  name = "ec2-abac-s3-allowed"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # RBAC: least-privilege read on the demo bucket. Identical to the denied role — proving that RBAC
  # alone is NOT what stops the other instance; the bucket-policy ABAC gate is.
  inline_policies = {
    s3-read = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ListBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = [local.bucket_arn]
        },
        {
          Sid      = "GetObject"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${local.bucket_arn}/*"]
        },
      ]
    })
  }

  # ABAC attribute: this tag surfaces as aws:PrincipalTag/project on the instance's role session.
  tags = {
    Environment = "lab"
    project     = "abac-lab"
  }
}
