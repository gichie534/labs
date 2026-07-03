# The demo bucket plus the resource-side half of the evaluation matrix.
#
# In a single account, S3 access for a request is decided by combining the caller's IAM identity
# policy with this bucket (resource) policy: an explicit Deny on EITHER side always wins; otherwise
# the request is allowed if EITHER side Allows it; with no Allow anywhere it's an implicit deny. This
# bucket policy encodes two of the four matrix cells (the other two are pure identity-side / silence):
#
#   - bucket-only role   -> explicit Allow s3:GetObject  (its identity policy grants nothing)   -> READ OK
#   - explicit-deny role -> explicit Deny  s3:GetObject  (its identity policy DOES grant it)    -> AccessDenied
#   - identity-only role -> (silent)  -> relies on its own identity Allow                       -> READ OK
#   - neither role       -> (silent)  -> no Allow anywhere                                       -> AccessDenied
#
# Both statements are scoped by Principal to the specific lab role ARNs so they can't affect the
# bucket owner/admin. The bucket itself is sourced from the modules repo by pinned tag; the policy is
# lab-specific composition.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.1.0"
}

locals {
  bucket     = get_env("DEMO_BUCKET", "s3-policy-eval-matrix-lab")
  bucket_arn = "arn:aws:s3:::${local.bucket}"
}

dependency "iam_bucket_only" {
  config_path = "../iam-bucket-only"

  mock_outputs = {
    role_arn = "arn:aws:iam::000000000000:role/s3-eval-bucket-only"
  }
}

dependency "iam_explicit_deny" {
  config_path = "../iam-explicit-deny"

  mock_outputs = {
    role_arn = "arn:aws:iam::000000000000:role/s3-eval-explicit-deny"
  }
}

inputs = {
  bucket_name = local.bucket

  # Lab bucket — allow clean teardown of a non-empty bucket.
  force_destroy = true

  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Resource-side Allow: lets the bucket-only role read even though its identity policy is empty.
      {
        Sid    = "AllowBucketOnlyRoleRead"
        Effect = "Allow"
        Principal = {
          AWS = [dependency.iam_bucket_only.outputs.role_arn]
        }
        Action   = ["s3:GetObject"]
        Resource = ["${local.bucket_arn}/*"]
      },
      # Explicit Deny: overrides the explicit-deny role's identity-side Allow. Deny always wins.
      {
        Sid    = "DenyExplicitDenyRoleRead"
        Effect = "Deny"
        Principal = {
          AWS = [dependency.iam_explicit_deny.outputs.role_arn]
        }
        Action   = ["s3:GetObject"]
        Resource = ["${local.bucket_arn}/*"]
      },
    ]
  })

  tags = {
    Environment = "lab"
  }
}
