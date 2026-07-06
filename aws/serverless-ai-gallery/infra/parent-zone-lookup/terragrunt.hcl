# Lab-local zone lookup. Sourced from a local path (not the modules repo) because it's lab-specific
# glue — resolving the EXISTING parent hosted zone so this lab can delegate a child zone from it. It
# creates NO resources.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

inputs = {
  zone_name = get_env("PARENT_ZONE_NAME", "REPLACE_WITH_PARENT_ZONE_NAME")
}
