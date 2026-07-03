# Lab-local seed unit (local path, creates the probe.txt fixture object). Depends on the s3 unit so
# the bucket exists first; the instance units depend on this so the object exists before they boot.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "s3" {
  config_path = "../s3"

  mock_outputs = {
    bucket = "mock-bucket"
    arn    = "arn:aws:s3:::mock-bucket"
  }
}

inputs = {
  bucket = dependency.s3.outputs.bucket
}
