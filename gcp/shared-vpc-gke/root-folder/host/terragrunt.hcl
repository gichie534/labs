# HOST PROJECT node — owns the shared VPC (see ./vpc) and the per-subnet grants (./shared-vpc-access).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/host-project.hcl"
}

inputs = {
  name       = "svc-vpc-host"
  project_id = include.root.locals.host_project_id
  # GKE on a Shared VPC provisions a container service agent in the HOST project too (to manage the
  # cluster's firewall rules there), so the host needs the Container API enabled — not just Compute.
  activate_apis   = ["compute.googleapis.com", "container.googleapis.com"]
  deletion_policy = "DELETE"
}
