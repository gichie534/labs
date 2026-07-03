# The Application Load Balancer — the point of the lab.
#
# One internet-facing ALB with a single HTTP listener that demonstrates BOTH routing styles at once:
#
#   path-based:  /a, /a/*            -> target group "a" -> app-a
#                /b, /b/*            -> target group "b" -> app-b
#   host-based:  Host: a.alb.lab     -> target group "a" -> app-a
#                Host: b.alb.lab     -> target group "b" -> app-b
#   no match:    -> fixed 404 (no default_target_group_key set)
#
# Rules are evaluated by ascending priority. Host-based routing is demonstrated with
# `curl -H "Host: a.alb.lab"` (see the Taskfile / README) so the lab needs no real DNS or domain.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/alb?ref=aws-alb-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    ami_id     = "ami-00000000000000000"
    vpc_id     = "vpc-mock"
    subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "app_a" {
  config_path = "../app-a"

  mock_outputs = {
    id = "i-mockaaaaaaaaaaaaa"
  }
}

dependency "app_b" {
  config_path = "../app-b"

  mock_outputs = {
    id = "i-mockbbbbbbbbbbbbb"
  }
}

inputs = {
  name       = "alb-routing-lab"
  vpc_id     = dependency.lookups.outputs.vpc_id
  subnet_ids = dependency.lookups.outputs.subnet_ids

  # One target group per backend, each with a single registered instance.
  target_groups = {
    a = {
      port              = 80
      target_ids        = [dependency.app_a.outputs.id]
      health_check_path = "/"
    }
    b = {
      port              = 80
      target_ids        = [dependency.app_b.outputs.id]
      health_check_path = "/"
    }
  }

  # Both routing styles on the same listener. Path rules first (lower priority numbers), then host.
  listener_rules = {
    path_a = { priority = 10, target_group_key = "a", path_patterns = ["/a", "/a/*"] }
    path_b = { priority = 20, target_group_key = "b", path_patterns = ["/b", "/b/*"] }
    host_a = { priority = 30, target_group_key = "a", host_headers = ["a.alb.lab"] }
    host_b = { priority = 40, target_group_key = "b", host_headers = ["b.alb.lab"] }
  }

  tags = {
    Environment = "lab"
  }
}
