# The static-website bucket (default CloudFront origin). Sourced from the hardened s3-bucket module
# by pinned tag; it stays fully private (all public access blocked) and is reachable only through
# CloudFront's Origin Access Control. Depends on `cdn` for the distribution ARN its OAC policy trusts.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.1.0"
}

locals {
  bucket     = "${get_env("BUCKET_PREFIX", "s3-cloudfront-routing-lab")}-site"
  bucket_arn = "arn:aws:s3:::${local.bucket}"
}

dependency "cdn" {
  config_path = "../cdn"

  mock_outputs = {
    distribution_arn = "arn:aws:cloudfront::000000000000:distribution/MOCKDIST"
  }
}

inputs = {
  bucket_name   = local.bucket
  force_destroy = true # throwaway lab: destroy cleanly without emptying first

  # OAC: allow ONLY the CloudFront service principal, and only for this distribution.
  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = dependency.cdn.outputs.distribution_arn
          }
        }
      },
    ]
  })

  tags = {
    Environment = "lab"
    Role        = "static-site"
  }
}
