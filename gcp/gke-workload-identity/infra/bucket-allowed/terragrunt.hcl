# The "allowed" data bucket. The workload's KSA is granted roles/storage.objectViewer here (in the
# workload-identity unit), so reads from this bucket succeed. Seeded with data by `task gke-wi:seed`.
#
# Pure producer: this unit only creates the bucket and exports its name. Access is granted by the
# workload-identity unit, keeping the bucket's policy with the workload that needs it.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id     = include.root.locals.project_id
  region         = include.root.locals.region
  bucket_allowed = include.root.locals.bucket_allowed
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gcs?ref=gcp-gcs-v0.1.0"
}

inputs = {
  project_id = local.project_id
  name       = local.bucket_allowed
  location   = local.region

  # Lab buckets are torn down with `task gke-wi:down`; allow deleting seeded objects with them.
  force_destroy = true

  labels = {
    lab    = "gke-workload-identity"
    access = "allowed"
  }
}
