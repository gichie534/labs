# 0001 — A business-insights agent in Slack, over three data stores

Status: accepted
Date: 2026-11-18

## Context

The lab exists to learn the full agent lifecycle on Gemini Enterprise Agent Platform: build, evaluate,
deploy, version, secure, give access to Google Cloud resources, observe. The agent's job only matters as
far as it exercises those stages. Three candidates were considered:

- **A business analyst in Slack over company data** (chosen).
- An ops/FinOps analyst over the lab's own billing export and audit logs. The data is real, but sparse in a
  lab account, nobody can check the answers, and audit logs are sensitive.
- An agent that takes actions (ticket triage that writes back). It teaches human-in-the-loop approval,
  but it's a different lab.

## Decision

An ADK agent answers business questions ("what did customer X do last month", "compare category Y
between the last two months") from Slack. The data is Looker's synthetic `thelook_ecommerce` public
dataset, copied into the lab and split across three stores on purpose:

| Store                      | Holds                                        | Agent reaches it through                                                                 | What it teaches                                                                                                                                                          |
| -------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cloud SQL PostgreSQL `crm` | users, orders                                | Cloud SQL remote MCP server (read-only toolset, Data API), as a borrowed service account | MCP on Google APIs, Data API to a Private Service Connect instance with no endpoint and no public IP, IAM database login, service account impersonation, DB-level grants |
| BigQuery `bi_analytics`    | events, order_items, products                | BigQuery remote MCP server (read-only tools)                                             | dataset-scoped IAM, job labels and timeouts, cost attribution                                                                                                            |
| GCS docs bucket            | metric definitions, periods, data-source map | ADK function tool + Cloud Storage client                                                 | non-MCP tools under the same identity, grounding answers in company definitions                                                                                          |

A fourth store, `bi_crm_snapshot` (BigQuery), holds the CRM tables but is **not** readable by the agent. It's
the seed source for Cloud SQL and the ground truth for evaluation. It also gives a ready-made IAM denial to
observe.

## Consequences

- **Answers can be graded.** Every eval question has a SQL answer computed from the same snapshot, so the eval
  gate checks facts instead of judging prose (ADR 0005).
- **Real tool selection and cross-source reasoning.** "What did customer X do" needs a CRM lookup (email ->
  `user_id`), then warehouse queries. No single query can answer it.
- **The CRM instance has no network surface.** The organization enforces `constraints/sql.restrictPublicIp`,
  so the instance has no public IP. It is Private Service Connect-enabled with no PSC endpoint, so it needs no
  VPC, peering or reserved range. The Data API and `gcloud sql import` run on Google's side, which is all the
  agent and `task seed` use. Private Service Access would also work but costs a VPC with nothing in it.
  Direct `psql` access needs a PSC endpoint in some VPC; the lab doesn't create one.
- **Cost.** Cloud SQL (db-f1-micro) is the only always-on resource. `task down` removes it. Agent Runtime
  scales to zero, and BigQuery is billed per query.
- **The data is synthetic and shifts daily upstream.** The lab's copy is a snapshot (`task seed`), and
  relative periods ("last month") use the current date. Re-seed when the snapshot gets old.
