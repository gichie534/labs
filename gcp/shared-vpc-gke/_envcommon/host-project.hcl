# ---------------------------------------------------------------------------------------------------------------------
# TEMPLATE: Shared VPC HOST project (inside a folder)
# Including unit sets `name`, `project_id`, and `activate_apis`. The parent folder is the directory
# one level up; its `id` output is wired into `folder_id`. Billing comes from root.hcl.
#
# Sourced from the local infrastructure-catalog checkout while gcp/host-project is unreleased —
# TODO: switch to git::...//modules/gcp/host-project?ref=gcp-host-project-v0.1.0.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${local.root.locals.catalog_modules}/gcp/host-project"
}

dependency "parent" {
  config_path  = "${get_terragrunt_dir()}/.."
  mock_outputs = { id = "folders/000000000000" }
}

inputs = {
  folder_id       = dependency.parent.outputs.id
  billing_account = local.root.locals.billing_account
}
