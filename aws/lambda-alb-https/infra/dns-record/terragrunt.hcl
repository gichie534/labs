# Lab-local DNS record unit. Sourced from a local path (not the modules repo) because it's
# lab-specific glue — an alias record to this lab's ALB — not reusable infrastructure.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "zone_lookup" {
  config_path = "../zone-lookup"

  mock_outputs = {
    zone_id   = "Z0000000000000000000"
    zone_name = "example.com"
  }
}

dependency "alb" {
  config_path = "../alb"

  mock_outputs = {
    dns_name = "lambda-alb-https-000000000.us-east-1.elb.amazonaws.com"
    zone_id  = "Z00000000000000000000"
  }
}

inputs = {
  app_domain     = get_env("APP_DOMAIN", "REPLACE_WITH_APP_DOMAIN")
  hosted_zone_id = dependency.zone_lookup.outputs.zone_id
  alb_dns_name   = dependency.alb.outputs.dns_name
  alb_zone_id    = dependency.alb.outputs.zone_id
}
