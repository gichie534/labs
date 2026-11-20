# Dashboard + alerts for the agent and the Slack bridge.
#
# Agent Runtime publishes request_count / request_latencies / cpu+memory allocation_time under the monitored
# resource aiplatform.googleapis.com/ReasoningEngine. Traces (one span per model call and tool call, with prompts
# when OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true) are in Cloud Trace — not alertable, but linked from
# the dashboard description.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  r = include.root.locals

  agent_resource = "resource.type=\"aiplatform.googleapis.com/ReasoningEngine\""
  bridge_filter  = "resource.type=\"cloud_run_revision\" resource.labels.service_name=one_of(\"${include.root.locals.names.ingress_service}\",\"${include.root.locals.names.worker_service}\")"
}

terraform {
  source = "${include.root.locals.catalog_local}/monitoring"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    engine_id = "0000000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "channels" {
  config_path = "../../monitoring/channels"
  mock_outputs = {
    ids = ["projects/mock-project/notificationChannels/0"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id               = local.r.project_id
  notification_channel_ids = dependency.channels.outputs.ids
  user_labels              = local.r.labels

  dashboards = {
    agent = jsonencode({
      displayName = "Business insights agent"
      mosaicLayout = {
        columns = 12
        tiles = [
          {
            xPos = 0, yPos = 0, width = 6, height = 4
            widget = {
              title = "Agent requests by response class"
              xyChart = {
                dataSets = [{
                  plotType = "STACKED_BAR"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "metric.type=\"aiplatform.googleapis.com/reasoning_engine/request_count\" ${local.agent_resource} resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\""
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_DELTA"
                        crossSeriesReducer = "REDUCE_SUM"
                        groupByFields      = ["metric.label.response_code_class"]
                      }
                    }
                  }
                }]
              }
            }
          },
          {
            xPos = 6, yPos = 0, width = 6, height = 4
            widget = {
              title = "Agent latency p50 / p95 (ms)"
              xyChart = {
                dataSets = [
                  for p in ["50", "95"] : {
                    plotType       = "LINE"
                    legendTemplate = "p${p}"
                    timeSeriesQuery = {
                      timeSeriesFilter = {
                        filter = "metric.type=\"aiplatform.googleapis.com/reasoning_engine/request_latencies\" ${local.agent_resource} resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\""
                        aggregation = {
                          alignmentPeriod    = "300s"
                          perSeriesAligner   = "ALIGN_PERCENTILE_${p}"
                          crossSeriesReducer = "REDUCE_MAX"
                        }
                      }
                    }
                  }
                ]
              }
            }
          },
          {
            xPos = 0, yPos = 4, width = 6, height = 4
            widget = {
              title = "Agent CPU allocation (s/s)"
              xyChart = {
                dataSets = [{
                  plotType = "LINE"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "metric.type=\"aiplatform.googleapis.com/reasoning_engine/cpu/allocation_time\" ${local.agent_resource} resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\""
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                      }
                    }
                  }
                }]
              }
            }
          },
          {
            xPos = 6, yPos = 4, width = 6, height = 4
            widget = {
              title = "Slack bridge requests by service and response class"
              xyChart = {
                dataSets = [{
                  plotType = "STACKED_BAR"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "metric.type=\"run.googleapis.com/request_count\" ${local.bridge_filter}"
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_DELTA"
                        crossSeriesReducer = "REDUCE_SUM"
                        groupByFields      = ["resource.label.service_name", "metric.label.response_code_class"]
                      }
                    }
                  }
                }]
              }
            }
          },
        ]
      }
    })
  }

  threshold_alerts = {
    agent_errors = {
      display_name = "Business insights agent: 5xx responses"
      filter       = "metric.type=\"aiplatform.googleapis.com/reasoning_engine/request_count\" ${local.agent_resource} resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\" metric.labels.response_code_class=\"5xx\""
      comparison   = "COMPARISON_GT"
      threshold    = 0
      duration     = "0s"
      alignment    = "300s"
      aligner      = "ALIGN_DELTA"
      reducer      = "REDUCE_SUM"
      severity     = "ERROR"
      documentation = join("\n", [
        "The agent returned server errors. Start with the agent's logs:",
        "`resource.type=\"aiplatform.googleapis.com/ReasoningEngine\" resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\" severity>=ERROR`.",
        "A new revision is the usual suspect: `task traffic:status`, then `task traffic:rollback`.",
      ])
    }
    agent_latency = {
      display_name = "Business insights agent: p95 latency above 2 minutes"
      filter       = "metric.type=\"aiplatform.googleapis.com/reasoning_engine/request_latencies\" ${local.agent_resource} resource.labels.reasoning_engine_id=\"${dependency.agent.outputs.engine_id}\""
      comparison   = "COMPARISON_GT"
      threshold    = 120000
      duration     = "600s"
      alignment    = "300s"
      aligner      = "ALIGN_PERCENTILE_95"
      reducer      = "REDUCE_MAX"
      documentation = join("\n", [
        "Answers are slow. Open a slow trace in Cloud Trace (Trace Explorer, service = the agent) and look for",
        "repeated tool calls (the model retrying SQL) or a long BigQuery job.",
      ])
    }
    bridge_errors = {
      display_name  = "Slack bridge: 5xx responses"
      filter        = "metric.type=\"run.googleapis.com/request_count\" ${local.bridge_filter} metric.labels.response_code_class=\"5xx\""
      comparison    = "COMPARISON_GT"
      threshold     = 0
      duration      = "0s"
      alignment     = "300s"
      aligner       = "ALIGN_DELTA"
      reducer       = "REDUCE_SUM"
      group_by      = ["resource.label.service_name"]
      severity      = "ERROR"
      documentation = "The ingress or worker returned 5xx. Check the service logs in Cloud Run; the worker logs every agent call with the session ID."
    }
  }

  log_match_alerts = {
    agent_permission_denied = {
      display_name = "Business insights agent: permission denied"
      filter = join(" AND ", [
        "logName:\"cloudaudit.googleapis.com\"",
        "protoPayload.status.code=7",
        "protoPayload.authenticationInfo.principalSubject:\"reasoningEngines/${dependency.agent.outputs.engine_id}\"",
      ])
      documentation = join("\n", [
        "Google Cloud denied an API call made by the agent's own identity. Either the agent tried to reach data it",
        "must not (expected when someone probes it — check the Slack thread) or a grant is missing in iam/agent.",
      ])
    }
    worker_errors = {
      display_name  = "Slack worker: errors"
      filter        = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${local.r.names.worker_service}\" AND severity>=ERROR"
      documentation = "The worker failed to answer a Slack message. The log entry carries the Slack channel, thread and agent session ID."
    }
  }
}
