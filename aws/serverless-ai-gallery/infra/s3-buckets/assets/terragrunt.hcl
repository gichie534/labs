# The website-assets bucket — where the push Lambda stores processed images (images/uploads/ prefix).
# It stays private; the fetch Lambda hands out short-lived presigned GET URLs so the gallery can
# display images without the bucket ever being public.
#
# Sourced from the modules repo by pinned tag.

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
  bucket_name   = "${local.account_id}-ai-gallery-assets-${local.region}"
  force_destroy = true # throwaway lab: destroy cleanly without emptying first

  tags = {
    Environment = "lab"
  }
}
