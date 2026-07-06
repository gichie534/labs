# The upload bucket — where the browser PUTs raw images via a presigned URL (uploads/ prefix). It
# stays private (the module blocks all public access); the presigned URL is the authorization. CORS
# allows the browser PUT from the upload page's origin. An ObjectCreated event on this bucket triggers
# the push Lambda (wired in the upload-events unit).
#
# Sourced from the modules repo by pinned tag (s3-bucket v0.2.0 adds cors_rules).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.2.0"
}

locals {
  account_id = get_env("AWS_ACCOUNT_ID", "REPLACE_WITH_ACCOUNT_ID")
  region     = get_env("AWS_REGION", "us-east-1")
}

inputs = {
  bucket_name   = "${local.account_id}-ai-gallery-uploads-${local.region}"
  force_destroy = true # throwaway lab: destroy cleanly without emptying first

  # The browser PUTs the image directly to S3 with a presigned URL. allow_origins is "*" because the
  # upload page is served from the upload Lambda's Function URL (a dynamic origin); the presigned URL
  # — not CORS — is what authorizes the write, and presigned PUTs carry no cookies/credentials.
  cors_rules = [
    {
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      allowed_headers = ["*"]
      expose_headers  = ["ETag"]
      max_age_seconds = 3600
    },
  ]

  tags = {
    Environment = "lab"
  }
}
