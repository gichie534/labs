# 0002 — Terraform owns the agent's engine, the pipeline owns its revisions

Status: accepted
Date: 2026-11-18

## Context

An Agent Runtime agent is a `reasoningEngines` resource. With Agent Identity, its IAM principal is derived
from the engine ID:

```
principal://agents.global.org-<ORG>.system.id.goog/resources/aiplatform/projects/<NUMBER>/locations/<REGION>/reasoningEngines/<ID>
```

Re-creating the engine mints a new principal. Every grant to the old one (BigQuery, GCS, the right to
borrow the Cloud SQL reader account) stops applying, with no error until the agent hits a 403. The platform docs call out
blue/green-by-recreation and Terraform-recreates-it as the way this goes wrong.

The platform supports **revisions**: updating a versioned field (source, entrypoint, class methods, env,
scaling, identity) creates an immutable revision of the same engine. **Traffic splitting** then routes a
percentage to each active revision. Both are Public Preview and v1beta1-only, and Terraform doesn't manage
traffic.

The options:

1. Terraform owns everything, including code (`source_code_spec`). Each release is a `terraform apply`.
   CI would need state access and broad permissions, and there's no traffic control.
2. The SDK owns everything (`client.runtimes.create`). IAM grants then need the engine ID from a script,
   and the infrastructure stops being declarative.
3. **Terraform owns a long-lived "shell"; the pipeline owns code and traffic** (chosen).

## Decision

- `infra/agent-runtime/business-insights` (module `gcp/agent-runtime`) creates the engine with
  `identity_type = AGENT_IDENTITY`, Memory Bank topics and the invoker grant. It deploys **no code** and
  sets **no `deployment_spec`**: the API refuses one on an engine without code. It ignores every field the
  pipeline owns (`source_code_spec`, `class_methods`, `agent_framework`, the whole `deployment_spec`), so
  `terraform apply` never rolls a release back.
- `app/python/lifecycle/release.py` ships code with `client.runtimes.update(...)` from source files, together
  with the revision's env and **scaling** (min/max instances, CPU/memory, concurrency). Each release becomes a
  revision, so a rollback restores the old sizing along with the old code. The script first pins the current
  split, so the new revision starts at **0%**.
- The optional Agent Gateway binding (`deployment_spec.agent_gateway_config`) is also set with the SDK, by
  `task gateway:bind` (ADR 0006).
- Traffic moves explicitly: `canary` (10%), `promote` (100%), `rollback`. Each revision's environment
  carries `BI_RELEASE` (the git SHA), so the platform itself shows which code runs where.
- Data access is granted once, in Terraform, to the engine's principal (`infra/iam/agent`). Baseline roles go
  to the project principal set (`infra/iam/all-agents`), which survives even a re-creation.

## Consequences

- An agent release needs only `roles/aiplatform.user`, not Terraform state. CI does release → eval → canary
  in about five minutes.
- Two writers on one resource. The split of fields is documented in the module's `ignore_changes` and here:
  Terraform owns identity, Memory Bank and invokers; the pipeline owns code and everything in
  `deployment_spec`.
- Scaling isn't declared in Terraform. It's in `release.py` (overridable with `AGENT_*` env vars) and visible
  per revision in `task traffic:status` / the console.
- The engine must exist before the first release. `task up` creates it, then `task deploy:agent` sends the
  first revision (100% traffic).
- `task down` destroys the engine with `deletion_policy = FORCE`, including sessions and memories.
