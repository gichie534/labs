# The internet-facing ALB — the public entry point for the gallery. It terminates TLS with the ACM
# certificate and forwards to a single "app" target group of type `ip` (Fargate/awsvpc registers task
# ENIs by IP). The HTTP :80 listener 301-redirects to HTTPS :443. Health checks hit /healthz.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/alb?ref=aws-alb-v0.3.0"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "cert" {
  config_path = "../cert"

  mock_outputs = {
    certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000"
  }
}

inputs = {
  name       = "serverless-ai-gallery"
  vpc_id     = dependency.network.outputs.vpc_id
  subnet_ids = dependency.network.outputs.public_subnet_ids

  # TLS termination — turns :80 into a 301 redirect to :443 and serves traffic on the HTTPS listener.
  certificate_arn = dependency.cert.outputs.certificate_arn

  # One target group for the Fargate gallery. target_type = ip is required for awsvpc networking.
  target_groups = {
    app = {
      port                 = 8080
      protocol             = "HTTP"
      target_type          = "ip"
      health_check_path    = "/healthz"
      health_check_matcher = "200"
    }
  }

  default_target_group_key = "app"

  tags = {
    Environment = "lab"
  }
}
