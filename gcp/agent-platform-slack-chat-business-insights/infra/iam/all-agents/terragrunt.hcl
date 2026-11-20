# Baseline grants for EVERY Agent Runtime agent in the project, bound to the project principal set
#   principalSet://agents.global.org-<ORG>.system.id.goog/attribute.platformContainer/aiplatform/projects/<NUMBER>
# A principal set survives engine re-creation, so these never go missing after a redeploy. Only harmless,
# project-wide roles belong here: quota, logs, metrics, traces. Data access is per agent (iam/agent unit).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_local}/principal-iam"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    project_principal_set = "principalSet://agents.global.org-000000000000.system.id.goog/attribute.platformContainer/aiplatform/projects/000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id = include.root.locals.project_id
  member     = dependency.agent.outputs.project_principal_set

  project_roles = [
    "roles/serviceusage.serviceUsageConsumer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/telemetry.tracesWriter",
    "roles/cloudtrace.agent",
  ]
}
