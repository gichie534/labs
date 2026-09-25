# The one bucket BOTH ingestion paths land in. Having a single destination is what makes the
# comparison honest — the two paths differ in how data arrives, not in where it ends up.
#
#   batch/   written directly by `task upload` (a single PutObject)
#   stream/  written by Firehose once its buffer flushes
#   errors/  records Firehose could not deliver
#
# force_destroy is on because the lab is meant to be torn down; without it `task down` fails on a
# non-empty bucket and leaves the warehouse running.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/s3-bucket?ref=aws-s3-bucket-v0.3.0"
}

inputs = {
  bucket_name   = get_env("DATA_BUCKET", "REPLACE_WITH_DATA_BUCKET")
  force_destroy = true

  tags = {
    Environment = "lab"
  }
}
