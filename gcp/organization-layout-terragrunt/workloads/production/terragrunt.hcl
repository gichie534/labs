include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/folder.hcl"
}

inputs = {
  display_name        = "production"
  deletion_protection = false
}
