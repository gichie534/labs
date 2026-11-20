# Business documents the agent reads to answer consistently: metric definitions, what counts as an active
# customer, how revenue is computed. Seeded from data/docs/ by `task seed`. The agent gets objectViewer here
# (iam/agent unit) — and only here, not on the seed bucket.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/gcs?ref=gcp-gcs-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id    = include.root.locals.project_id
  name          = include.root.locals.names.docs_bucket
  location      = include.root.locals.region
  force_destroy = true
  labels        = include.root.locals.labels
}
