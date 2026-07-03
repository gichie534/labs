# IAM identity for the IDENTITY-ONLY instance (matrix cell: identity=Allow, bucket=silent).
#
# Its inline identity policy grants s3:GetObject on the demo object. The bucket policy says NOTHING
# about this role. In a single account, access is granted if EITHER the identity policy OR the bucket
# policy allows it and nothing explicitly denies it — so the identity Allow alone is enough. Expected
# result: the read SUCCEEDS.
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
  name = "s3-eval-identity-only"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # Identity-side grant: read the probe object. This is the ONLY side that allows the read for this
  # instance (the bucket policy is silent about it).
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
