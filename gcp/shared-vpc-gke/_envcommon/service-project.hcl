# ---------------------------------------------------------------------------------------------------------------------
# TEMPLATE: Shared VPC SERVICE project (inside a folder)
# Including unit sets `name`, `project_id`, and `activate_apis`. The parent folder is the directory
# one level up; the Shared VPC host is the sibling `host` project node. Both are wired here so the
# node only declares its own identity. Billing comes from root.hcl.
#
# Sourced from the local infrastructure-catalog checkout while gcp/service-project is unreleased —
# TODO: switch to git::...//modules/gcp/service-project?ref=gcp-service-project-v0.1.0.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${local.root.locals.catalog_modules}/gcp/service-project"
}

dependency "parent" {
  config_path  = "${get_terragrunt_dir()}/.."
  mock_outputs = { id = "folders/000000000000" }
}

# The Shared VPC host this service project attaches itself to (the sibling `host` project node).
dependency "host" {
  config_path  = "${get_terragrunt_dir()}/../host"
  mock_outputs = { host_project_id = "mock-host-project" }
}

inputs = {
  folder_id                  = dependency.parent.outputs.id
  billing_account            = local.root.locals.billing_account
  shared_vpc_host_project_id = dependency.host.outputs.host_project_id
}
