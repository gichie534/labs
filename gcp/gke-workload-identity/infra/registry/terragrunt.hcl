# Artifact Registry Docker repository holding the Go reader image CI builds and pushes.
#
# Image *pulls* are done by the GKE node service account (the default compute SA on Autopilot), so
# we grant that node SA repo-scoped reader here — otherwise pods fail with ImagePullBackOff. CI's
# push permission is granted separately as a direct-WIF role in the deployer-wif unit.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id     = include.root.locals.project_id
  region         = include.root.locals.region
  project_number = include.root.locals.project_number

  # Default GKE node service account on Autopilot.
  node_service_account = "${local.project_number}-compute@developer.gserviceaccount.com"
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/artifact-registry?ref=gcp-artifact-registry-v0.2.0"
}

inputs = {
  project_id    = local.project_id
  repository_id = "gke-workload-identity"
  location      = local.region
  format        = "DOCKER"
  description   = "Images for the gke-workload-identity lab."

  # Let the GKE nodes pull images from this repo.
  reader_members = {
    gke_nodes = "serviceAccount:${local.node_service_account}"
  }
}
