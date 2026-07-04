# The CloudFront distribution — the lab's single public entry point. It fronts three PRIVATE buckets
# via Origin Access Control and routes by path:
#   default (/) -> site bucket (index.html)   *.jpg -> jpg bucket   *.pdf -> pdf bucket
#
# This unit intentionally has NO dependency on the bucket units. It builds each origin's regional
# domain name from the (env-known) bucket names, which breaks what would otherwise be a cycle:
# the distribution needs the bucket domains, and each bucket policy needs the distribution ARN.
# So the distribution is created first; the buckets then depend on THIS unit for distribution_arn.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/cloudfront-s3?ref=aws-cloudfront-s3-v0.2.0"
}

locals {
  region = get_env("AWS_REGION", "us-east-1")
  prefix = get_env("BUCKET_PREFIX", "s3-cloudfront-routing-lab")

  # S3 REGIONAL domain names (required for OAC signing): <bucket>.s3.<region>.amazonaws.com
  site_domain = "${local.prefix}-site.s3.${local.region}.amazonaws.com"
  jpg_domain  = "${local.prefix}-jpg.s3.${local.region}.amazonaws.com"
  pdf_domain  = "${local.prefix}-pdf.s3.${local.region}.amazonaws.com"
}

inputs = {
  name    = local.prefix
  comment = "s3-cloudfront-routing lab — static site + jpg/pdf by path"

  origins = {
    site = { domain_name = local.site_domain }
    jpg  = { domain_name = local.jpg_domain }
    pdf  = { domain_name = local.pdf_domain }
  }

  # Anything not matched below is served by the static-site bucket.
  default_origin_key = "site"

  # Disable edge caching for this lab so edits to the buckets show up immediately instead of being
  # served stale from a CloudFront cache. Managed CachingDisabled policy id.
  cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

  ordered_cache_behaviors = [
    { path_pattern = "*.jpg", origin_key = "jpg" },
    { path_pattern = "*.pdf", origin_key = "pdf" },
  ]

  tags = {
    Environment = "lab"
  }
}
