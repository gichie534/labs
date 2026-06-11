include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/project.hcl"
}

inputs = {
  name            = "ProductionApp"
  project_id      = "prod-richard-org-test"
  deletion_policy = "DELETE"
  activate_apis   = ["compute.googleapis.com"]
}
