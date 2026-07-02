# IAM identity for the DENIED instance.
#
# RBAC layer: IDENTICAL to the allowed role — the same inline least-privilege policy granting
# s3:ListBucket + s3:GetObject on the demo bucket, plus AmazonSSMManagedInstanceCore. On RBAC alone,
# this role can read the bucket just fine.
#
# ABAC layer (the difference): this role does NOT carry the `project = abac-lab` tag. The demo
# bucket policy allows the S3 actions only when aws:PrincipalTag/project == "abac-lab", so this
# role's requests fail the bucket-policy condition and are denied — even though its identity policy
# (RBAC) allows them. That contrast is the lab's teaching point: RBAC says yes, ABAC says no.
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
  name = "ec2-abac-s3-denied"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # RBAC: byte-for-byte the same grant as the allowed role. If ABAC weren't in play, this instance
  # would read the bucket successfully.
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

  # NOTE: deliberately NO `project` tag here — this is what makes the bucket policy deny this role.
  tags = {
    Environment = "lab"
  }
}
