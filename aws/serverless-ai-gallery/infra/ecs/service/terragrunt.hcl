# The Fargate service — the gallery web container. It runs in the public subnets with a public IP (no
# NAT), registers its task IPs with the ALB's "app" target group, and is reachable only from the ALB.
# The container is created with a BOOTSTRAP image tag that doesn't exist yet; the first CI deploy (or
# `task deploy`) pushes a real image and rolls the service. ignore_task_definition_changes = true so
# Terraform stops managing the running revision after creation — CI owns rollouts.
#
# The three Lambda Function URLs are injected as environment variables; the Go server templates them
# into index.html/index.js at request time, so the image never needs the URLs baked in.
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
    repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/serverless-ai-gallery"
  }
}

dependency "upload_page" {
  config_path = "../../lambdas/upload-page"

  mock_outputs = {
    function_url = "https://mock-upload.lambda-url.us-east-1.on.aws/"
  }
}

dependency "fetch" {
  config_path = "../../lambdas/fetch"

  mock_outputs = {
    function_url = "https://mock-fetch.lambda-url.us-east-1.on.aws/"
  }
}

dependency "ai" {
  config_path = "../../lambdas/ai"

  mock_outputs = {
    function_url = "https://mock-ai.lambda-url.us-east-1.on.aws/"
  }
}

inputs = {
  name        = "serverless-ai-gallery"
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

  # Function URLs the gallery front-end calls; templated into the page at request time. The upload URL
  # is trimmed of its trailing slash so the "Upload New Image" link is clean.
  environment = {
    UPLOAD_PAGE_URL    = trimsuffix(dependency.upload_page.outputs.function_url, "/")
    FETCH_FUNCTION_URL = trimsuffix(dependency.fetch.outputs.function_url, "/")
    AI_FUNCTION_URL    = trimsuffix(dependency.ai.outputs.function_url, "/")
  }

  # CI owns rolling deployments.
  ignore_task_definition_changes = true

  tags = {
    Environment = "lab"
  }
}
