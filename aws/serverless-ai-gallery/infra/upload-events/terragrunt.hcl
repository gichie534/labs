# Lab-local glue wiring the upload bucket's ObjectCreated events (uploads/ prefix) to the push Lambda,
# plus the resource-based permission letting S3 invoke it. Sourced from a local path because it's
# lab-specific composition — connecting two things this lab created — not reusable infrastructure.
# It lives in its own unit (rather than the bucket or function unit) because it needs outputs from
# both, and the notification must be created after the function + its invoke permission exist.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "uploads" {
  config_path = "../s3-buckets/uploads"

  mock_outputs = {
    bucket = "mock-uploads-bucket"
    arn    = "arn:aws:s3:::mock-uploads-bucket"
  }
}

dependency "push" {
  config_path = "../lambdas/push"

  mock_outputs = {
    function_name = "ai-gallery-push"
    function_arn  = "arn:aws:lambda:us-east-1:000000000000:function:ai-gallery-push"
  }
}

inputs = {
  upload_bucket_id   = dependency.uploads.outputs.bucket
  upload_bucket_arn  = dependency.uploads.outputs.arn
  push_function_name = dependency.push.outputs.function_name
  push_function_arn  = dependency.push.outputs.function_arn
}
