# SERVICE PROJECT node — runs the Autopilot cluster (see ./gke) on the host's shared subnet.
# Attaches itself to the host project (wired in the service-project template). Needs the Container
# API so its GKE service agent exists before shared-vpc-access grants it network access.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/service-project.hcl"
}

inputs = {
  name            = "svc-gke-service"
  project_id      = include.root.locals.service_project_id
  activate_apis   = ["compute.googleapis.com", "container.googleapis.com"]
  deletion_policy = "DELETE"
}
