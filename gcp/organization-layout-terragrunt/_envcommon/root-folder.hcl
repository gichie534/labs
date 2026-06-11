# ---------------------------------------------------------------------------------------------------------------------
# TEMPLATE: root folder (directly under the organization)
# Including unit only needs to set `display_name`. Parent is the organization, derived statically from root.hcl,
# so a root folder has NO dependency on any other unit.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "git::git@github.com:gichie534/infrastructure-catalog.git//modules/gcp/folder?ref=gcp-folder-v0.3.0"
}

inputs = {
  parent = "organizations/${local.root.locals.org_id}"
}
