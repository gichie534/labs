# The "denied" data bucket. The workload's KSA is granted NOTHING here, so reads from this bucket
# fail with a 403 — the negative case that proves Workload Identity authorization is actually being
# enforced (not just that reads happen to work). Seeded with data by `task gke-wi:seed`.
#
# Pure producer: only creates the bucket and exports its name. No IAM grant references it anywhere.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id    = include.root.locals.project_id
  region        = include.root.locals.region
  bucket_denied = include.root.locals.bucket_denied
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gcs?ref=gcp-gcs-v0.1.0"
}

inputs = {
  project_id = local.project_id
  name       = local.bucket_denied
  location   = local.region

  force_destroy = true

  labels = {
    lab    = "gke-workload-identity"
    access = "denied"
  }
}
