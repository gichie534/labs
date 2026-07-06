# Lab-local DNS record unit. Sourced from a local path (not the modules repo) because it's
# lab-specific glue — an alias record to this lab's ALB — not reusable infrastructure. It's separate
# from the route53 module because an ALIAS to a load balancer needs the ALB's dns_name + zone_id, and
# it must be created AFTER the ALB while the zone is created BEFORE the cert (avoids a dependency
# cycle: zone -> cert -> alb -> record).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "zone" {
  config_path = "../zone"

  mock_outputs = {
    zone_id = "Z0000000000000000000"
  }
}

dependency "alb" {
  config_path = "../alb"

  mock_outputs = {
    dns_name = "serverless-ai-gallery-000000000.us-east-1.elb.amazonaws.com"
    zone_id  = "Z00000000000000000000"
  }
}

inputs = {
  app_domain     = get_env("APP_DOMAIN", "REPLACE_WITH_APP_DOMAIN")
  hosted_zone_id = dependency.zone.outputs.zone_id
  alb_dns_name   = dependency.alb.outputs.dns_name
  alb_zone_id    = dependency.alb.outputs.zone_id
}
