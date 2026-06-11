# RESOURCE unit: actual infra (vpc, gke, gcs, ...) lives in directories like this, under a project.
# It depends on the parent project's project_id.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "project" {
  config_path = "${get_terragrunt_dir()}/.."

  mock_outputs                            = { project_id = "mock-prod-app" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

terraform {
  source = "git::git@github.com:gichie534/infrastructure-catalog.git//modules/gcp/compute-engine?ref=gcp-compute-engine-v0.1.0"
}

inputs = {
  name       = "test-compute-engine"
  project_id = dependency.project.outputs.project_id
}
