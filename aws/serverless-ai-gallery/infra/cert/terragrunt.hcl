# The public ACM certificate for the app's hostname, DNS-validated in the delegated child zone. The
# module writes the validation records into the zone and blocks until the cert is ISSUED, so the alb
# unit (which consumes certificate_arn) only proceeds once TLS is ready.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/acm-certificate?ref=aws-acm-certificate-v0.1.0"
}

dependency "zone" {
  config_path = "../zone"

  mock_outputs = {
    zone_id = "Z0000000000000000000"
  }
}

inputs = {
  domain_name    = get_env("APP_DOMAIN", "REPLACE_WITH_APP_DOMAIN")
  hosted_zone_id = dependency.zone.outputs.zone_id

  tags = {
    Environment = "lab"
  }
}
