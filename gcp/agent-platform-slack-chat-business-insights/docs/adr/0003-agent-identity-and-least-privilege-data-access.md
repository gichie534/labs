# 0003 — The agent acts as its own Agent Identity, and borrows a service account for Cloud SQL

Status: accepted
Date: 2026-11-18

## Context

Whose authority does the agent use when it queries data?

- **User delegation** (the agent acts on behalf of the Slack user, and logs show both identities). Slack users
  aren't Google identities, so this needs Slack-to-Google account linking and an OAuth consent flow. It's
  a separate project.
- **A service account** for the whole agent. This works, but the platform now offers **Agent Identity**: a
  per-agent SPIFFE principal, tied to the engine's lifecycle, with credentials bound to the runtime's mTLS
  certificate (Context-Aware Access). A stolen token can't be replayed elsewhere. Agent Gateway also
  requires it.

Cloud SQL is the exception. The Cloud SQL MCP server runs SQL through the Data API, which logs in to the
database **as the caller** unless it is given a built-in user and a password. Cloud SQL IAM database
authentication supports users, service accounts, groups, workforce identities and Entra ID, but **not**
Agent Identity principals. Two ways around that:

- a built-in database user whose password lives in a regional secret, which the MCP server reads with the
  agent's credentials (the first version of this lab);
- the agent **impersonates a service account** for Cloud SQL calls only, and that account is the IAM
  database user (chosen).

## Decision

The agent queries BigQuery and GCS as **its own Agent Identity**. For Cloud SQL it **borrows
`bi-crm-reader`**. Using its own identity, it mints a one-hour token for that account through the IAM
Credentials API (`generateAccessToken`, over mTLS on Agent Runtime) and calls the Cloud SQL MCP server with
it (`ImpersonatedHeaders` in `tools/google_mcp.py`). Cloud SQL then logs in as `bi-crm-reader@<project>.iam`.
No password exists anywhere.

Everything the agent may touch is in `infra/iam/agent`, granted to
`principal://.../reasoningEngines/<id>`:

| Grant                                  | Scope                            | Why                                                         |
| -------------------------------------- | -------------------------------- | ----------------------------------------------------------- |
| `roles/bigquery.dataViewer`            | dataset `bi_analytics` only      | read the warehouse; `bi_crm_snapshot` stays denied          |
| `roles/bigquery.jobUser`               | project                          | run query jobs                                              |
| `roles/mcp.toolUser`                   | project                          | `mcp.tools.call`, required for any Google remote MCP server |
| `roles/storage.objectViewer`           | the docs bucket only             | the glossary; the seed bucket stays denied                  |
| `roles/iam.serviceAccountTokenCreator` | the `bi-crm-reader` account only | borrow it for Cloud SQL                                     |

What the borrowed account can do (`infra/sa/crm-reader`, `data/crm/grants.sql.tmpl`):

| Grant                                             | Scope                  | Why                                                                                 |
| ------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------- |
| `roles/cloudsql.instanceUser`                     | project (one instance) | `cloudsql.instances.executeSql` + `login` for the Data API                          |
| `roles/mcp.toolUser`, `serviceUsageConsumer`      | project                | call the MCP tool, use project quota                                                |
| `CONNECT`, `USAGE`, `SELECT` on `users`, `orders` | database `crm`         | its entire database access; Cloud SQL creates IAM database users with no privileges |
| deny on read-write MCP tools                      | project                | `infra/iam-deny/agent-guardrails`                                                            |

Baseline roles (quota, logs, metrics, traces) go to the project's agent principal set (`infra/iam/all-agents`).

## Consequences

- **Passwordless.** There's no secret to rotate, nothing to leak, and no `user`/`passwordSecretVersion` in
  tool calls. The callback strips them, so the login is always IAM.
- **The borrowed token is a plain bearer token**, valid for up to an hour and not bound to the runtime's
  certificate like the agent's own. That's why the account is kept tiny and a deny policy covers it too.
  The `iam.serviceAccounts.getAccessToken` grant widens the agent's reach to exactly what `bi-crm-reader`
  can do.
- **Audit trail in two hops.** Cloud SQL logs show `bi-crm-reader` as the caller. Each mint is an IAM
  Credentials audit entry naming the agent principal as the caller and the account as the target.
  Correlate the two by time, or use the sqlcommenter tags.
- **Local development** mints the same token with your ADC. Set `DEVELOPER_MEMBER` (Owner doesn't include
  `getAccessToken`) or the Cloud SQL tool fails locally with a clear permission error.
- **Database grants are SQL, applied by `task seed`** (`data/crm/grants.sql.tmpl` via `gcloud sql import sql`,
  since the instance has no PSC endpoint and no public IP, so nothing can connect to it directly). Terraform's `google_sql_user.database_roles` could assign
  PostgreSQL's `pg_read_all_data` instead and remove the file. It was rejected because that role reads every
  table in every schema and database on the instance, present and future, plus system catalogs. Explicit
  SELECT on `users` and `orders` keeps the reader's database access exactly as wide as the question set.
- `roles/cloudsql.instanceUser` is project-scoped. It could be narrowed with an IAM condition on the
  instance name. With one instance in the project, the lab doesn't need that.
- Not verified until the first real run: that an Agent Identity principal may hold Token Creator on a
  service account and mint its tokens. It's standard IAM, but the lab is the first test of it.
