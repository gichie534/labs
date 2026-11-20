# Docker repository for the Go Slack bridge image (one image, two Cloud Run services). CI pushes here with the
# artifactregistry.writer role it gets in the wif/github-ci unit. Cloud Run pulls same-project images with its own
# service agent, so no reader grant is needed.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/artifact-registry?ref=gcp-artifact-registry-v0.2.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id    = include.root.locals.project_id
  repository_id = include.root.locals.names.bridge_repo
  location      = include.root.locals.region
  format        = "DOCKER"
  description   = "Slack bridge images for the agent-platform-slack-chat-business-insights lab."
  labels        = include.root.locals.labels
}
