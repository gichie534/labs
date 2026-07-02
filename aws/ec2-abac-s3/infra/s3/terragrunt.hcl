# The demo bucket the lab protects, plus the ABAC bucket policy — the resource-side half of the
# demonstration.
#
# Both lab roles already have identical RBAC (an identity policy granting s3:ListBucket +
# s3:GetObject on this bucket). This bucket policy adds the ABAC gate: an explicit Deny on the two
# lab roles whenever the request's aws:PrincipalTag/project is NOT "abac-lab".
#
#   - allowed role: carries tag project=abac-lab -> StringNotEquals is false -> Deny does NOT apply
#                   -> its identity policy lets it read.
#   - denied role:  has no project tag           -> StringNotEquals is true  -> Deny applies
#                   -> read blocked, despite the identical RBAC grant.
#
# The Deny is scoped to the two lab role ARNs so it can't lock out the bucket owner/admin. The bucket
# itself is sourced from the modules repo by pinned tag; the policy is lab-specific composition.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.1.0"
}

locals {
  bucket     = get_env("ABAC_BUCKET", "ec2-abac-s3-lab")
  bucket_arn = "arn:aws:s3:::${local.bucket}"
}

dependency "iam_allowed" {
  config_path = "../iam-allowed"

  mock_outputs = {
    role_arn = "arn:aws:iam::000000000000:role/ec2-abac-s3-allowed"
  }
}

dependency "iam_denied" {
  config_path = "../iam-denied"

  mock_outputs = {
    role_arn = "arn:aws:iam::000000000000:role/ec2-abac-s3-denied"
  }
}

inputs = {
  bucket_name = local.bucket

  # Lab bucket — allow clean teardown of a non-empty bucket.
  force_destroy = true

  # ABAC gate: deny the S3 read actions to the two lab roles unless the caller's principal tag
  # `project` equals "abac-lab". Absent tag (the denied role) fails StringNotEquals -> denied.
  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyReadWithoutProjectTag"
        Effect = "Deny"
        Principal = {
          AWS = [
            dependency.iam_allowed.outputs.role_arn,
            dependency.iam_denied.outputs.role_arn,
          ]
        }
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
        ]
        Resource = [
          local.bucket_arn,
          "${local.bucket_arn}/*",
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalTag/project" = "abac-lab"
          }
        }
      },
    ]
  })

  tags = {
    Environment = "lab"
  }
}
