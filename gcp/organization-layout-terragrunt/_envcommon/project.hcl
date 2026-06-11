# ---------------------------------------------------------------------------------------------------------------------
# TEMPLATE: project (inside a folder)
# Including unit only needs to set `name` and `project_id`. The parent folder is the directory one level up;
# its `id` output is wired into `folder_id` automatically. Billing comes from root.hcl.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "git::git@github.com:gichie534/infrastructure-catalog.git//modules/gcp/project?ref=gcp-project-v0.3.0"
}

dependency "parent" {
  config_path = "${get_terragrunt_dir()}/.."

  mock_outputs = { id = "folders/000000000000" }
}

inputs = {
  folder_id       = dependency.parent.outputs.id
  billing_account = local.root.locals.billing_account
}
