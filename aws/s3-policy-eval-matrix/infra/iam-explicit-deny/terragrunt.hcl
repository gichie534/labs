# IAM identity for the EXPLICIT-DENY instance (matrix cell: identity=Allow, bucket=explicit Deny).
#
# Its identity policy grants s3:GetObject on the demo object — exactly like the identity-only role.
# But the demo bucket policy carries an explicit Deny on s3:GetObject scoped to THIS role's ARN. In
# AWS policy evaluation an explicit Deny ALWAYS wins, overriding any Allow on either side. Expected
# result: the read FAILS with AccessDenied, even though the identity policy allows it. This is the
# cell that proves "explicit Deny beats Allow".
#
# The IAM role/profile itself is sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

locals {
  bucket     = get_env("DEMO_BUCKET", "s3-policy-eval-matrix-lab")
  bucket_arn = "arn:aws:s3:::${local.bucket}"
}

inputs = {
  name = "s3-eval-explicit-deny"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # Identity-side Allow — identical to identity-only. On its own this would permit the read; the
  # bucket policy's explicit Deny is what overrides it.
  inline_policies = {
    s3-read = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "GetObject"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${local.bucket_arn}/*"]
        },
      ]
    })
  }

  tags = {
    Environment = "lab"
  }
}
