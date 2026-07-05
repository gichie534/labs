# The internet-facing ALB — the public entry point. It terminates TLS with the ACM certificate and
# forwards every request to a single "app" target group of type `lambda`, which invokes the Go
# function. The module also grants Elastic Load Balancing permission to invoke the function and
# registers it. The HTTP :80 listener 301-redirects to HTTPS :443.
#
# Sourced from the modules repo by pinned tag (alb v0.3.0 adds Lambda target support).

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

dependency "function" {
  config_path = "../function"

  mock_outputs = {
    function_arn = "arn:aws:lambda:us-east-1:000000000000:function:lambda-alb-https"
  }
}

inputs = {
  name       = "lambda-alb-https"
  vpc_id     = dependency.network.outputs.vpc_id
  subnet_ids = dependency.network.outputs.public_subnet_ids

  # TLS termination — turns :80 into a 301 redirect to :443 and serves traffic on the HTTPS listener.
  certificate_arn = dependency.cert.outputs.certificate_arn

  # One lambda target group: pass the function ARN as the single target id. The module creates the
  # invoke permission and registers the function. A lambda target group has no port/protocol/vpc_id.
  target_groups = {
    app = {
      target_type = "lambda"
      target_ids  = [dependency.function.outputs.function_arn]
    }
  }

  # Single backend: unmatched requests forward to it (no listener_rules needed).
  default_target_group_key = "app"

  tags = {
    Environment = "lab"
  }
}
