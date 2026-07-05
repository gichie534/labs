# The Fargate service — the ECS workload. It runs in the public subnets with a public IP (no NAT),
# registers its task IPs with the ALB's "app" target group, and is reachable only from the ALB
# (the module creates a task SG allowing :8080 from the ALB's security group).
#
# The service is created with a BOOTSTRAP image (<repo>:bootstrap). ignore_task_definition_changes
# is true, so Terraform stops managing the running revision after creation — the GitHub Actions
# pipeline (and `task deploy`) register new task-def revisions with real image tags and roll the
# service, without Terraform reverting them. See the ADR.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ecs-fargate-service?ref=aws-ecs-fargate-service-v0.1.0"
}

dependency "network" {
  config_path = "../../network"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "cluster" {
  config_path = "../cluster"

  mock_outputs = {
    cluster_arn = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
  }
}

dependency "alb" {
  config_path = "../../alb"

  mock_outputs = {
    security_group_id = "sg-mock"
    target_group_arns = { app = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock/0000000000000000" }
  }
}

dependency "registry" {
  config_path = "../../registry"

  mock_outputs = {
    repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/ecs-fargate-https"
  }
}

inputs = {
  name        = "ecs-fargate-https"
  cluster_arn = dependency.cluster.outputs.cluster_arn

  # Bootstrap image; CI replaces it with real tags after the first deploy.
  container_image = "${dependency.registry.outputs.repository_url}:bootstrap"
  container_name  = "app"
  container_port  = 8080
  cpu             = 256
  memory          = 512

  vpc_id           = dependency.network.outputs.vpc_id
  subnet_ids       = dependency.network.outputs.public_subnet_ids
  assign_public_ip = true

  # Reachable only from the ALB.
  ingress_security_group_ids = [dependency.alb.outputs.security_group_id]

  # Register task IPs with the ALB target group.
  target_group_arn = dependency.alb.outputs.target_group_arns["app"]

  # CI owns rolling deployments.
  ignore_task_definition_changes = true

  tags = {
    Environment = "lab"
  }
}
