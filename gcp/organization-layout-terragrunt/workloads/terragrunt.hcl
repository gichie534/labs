include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/root-folder.hcl"
}

inputs = {
  display_name        = "workloads"
  deletion_protection = false
}
