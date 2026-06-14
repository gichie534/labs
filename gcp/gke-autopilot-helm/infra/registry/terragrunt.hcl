# Artifact Registry Docker repository that holds the Go "hello world" image CI builds and pushes.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/artifact-registry?ref=gcp-artifact-registry-v0.1.0"
}

inputs = {
  project_id    = local.project_id
  repository_id = "gke-autopilot-helm"
  location      = local.region
  format        = "DOCKER"
  description   = "Images for the gke-autopilot-helm lab."
}
