# Destination bucket for the cost and usage export.
#
# Deliberately a separate unit from the export itself, and deliberately dedicated to it: the export unit
# manages this bucket's policy (S3 allows exactly one policy per bucket), so nothing else may own a policy
# here. No bucket_policy is set below for that reason.
#
# The lifecycle rule is the whole reason a bucket like this needs thinking about. Hourly, resource-level
# cost data arrives every day and never stops, so "keep everything forever" is a cost decision — one
# nobody makes on purpose. 365 days is a year of history, which is what you want for year-over-year
# comparison, and no more.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.3.0"
}

locals {
  bucket = get_env("FINOPS_EXPORT_BUCKET", "REPLACE_WITH_EXPORT_BUCKET")
}

inputs = {
  bucket_name = local.bucket

  # Lab bucket: allow clean teardown without emptying it by hand first.
  force_destroy = true

  lifecycle_rules = [
    {
      id     = "expire-cost-exports"
      prefix = "cur2/"

      # A year of history, then gone. Tier first: after a month you are querying it rarely enough that
      # Standard-IA is the cheaper home for it.
      expiration_days = 365
      transitions = [
        {
          days          = 30
          storage_class = "STANDARD_IA"
        },
      ]

      # Failed multipart uploads are billed but invisible in the console.
      abort_incomplete_multipart_upload_days = 7
    },
  ]

  tags = {
    Environment = "lab"
  }
}
