# The delegated child hosted zone for the app domain (e.g. ai-gallery.aws.richardbatyrov.com). The
# module creates the public zone AND writes the NS delegation records into the parent zone, so the
# subdomain resolves through the parent. The cert and dns-record units write into THIS zone.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/route53?ref=aws-route53-v0.1.0"
}

dependency "parent" {
  config_path = "../parent-zone-lookup"

  mock_outputs = {
    zone_id   = "Z0000000000000000000"
    zone_name = "example.com"
  }
}

inputs = {
  name       = get_env("APP_DOMAIN", "REPLACE_WITH_APP_DOMAIN")
  visibility = "public"

  # Create the NS delegation records in the parent so the child zone resolves.
  delegate_to_parent_zone = {
    zone_id = dependency.parent.outputs.zone_id
  }

  force_destroy = true # throwaway lab

  tags = {
    Environment = "lab"
  }
}
