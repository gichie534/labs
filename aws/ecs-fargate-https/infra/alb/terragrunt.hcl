# The internet-facing ALB — the public entry point. It terminates TLS with the ACM certificate and
# forwards to a single "app" target group of type `ip` (Fargate/awsvpc registers task ENIs by IP,
# not instance). The HTTP :80 listener 301-redirects to HTTPS :443. Health checks hit /healthz.
#
# Sourced from the modules repo by pinned tag (alb v0.2.0 adds HTTPS termination).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/alb?ref=aws-alb-v0.2.0"
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
  name       = "ecs-fargate-https"
  vpc_id     = dependency.network.outputs.vpc_id
  subnet_ids = dependency.network.outputs.public_subnet_ids

  # TLS termination — turns :80 into a 301 redirect to :443 and serves traffic on the HTTPS listener.
  certificate_arn = dependency.cert.outputs.certificate_arn

  # One target group for the Fargate service. target_type = ip is required for awsvpc networking.
  # No target_ids: ECS registers/deregisters task IPs with the group as tasks come and go.
  target_groups = {
    app = {
      port                 = 8080
      protocol             = "HTTP"
      target_type          = "ip"
      health_check_path    = "/healthz"
      health_check_matcher = "200"
    }
  }

  # Single backend: unmatched requests forward to it (no listener_rules needed).
  default_target_group_key = "app"

  tags = {
    Environment = "lab"
  }
}
