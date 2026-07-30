# The lab's root folder under the organization. Holds the host and service project nodes.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/root-folder.hcl"
}

inputs = {
  display_name        = "shared-vpc-gke"
  deletion_protection = false
}
