# ---------------------------------------------------------------------------------------------------------------------
# TEMPLATE: nested folder (under another folder)
# Including unit only needs to set `display_name`. The parent folder is the directory one level up; its `id`
# output is wired in automatically. The dependency uses get_terragrunt_dir() so the relative path resolves
# against the INCLUDING unit's directory, not this template.
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  source = "git::git@github.com:gichie534/infrastructure-catalog.git//modules/gcp/folder?ref=gcp-folder-v0.3.0"
}

dependency "parent" {
  config_path = "${get_terragrunt_dir()}/.."

  mock_outputs = { id = "folders/000000000000" }
}

inputs = {
  parent = dependency.parent.outputs.id
}
