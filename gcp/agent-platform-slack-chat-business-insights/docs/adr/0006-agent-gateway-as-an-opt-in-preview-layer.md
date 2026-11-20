# 0006 — Agent Gateway as an opt-in preview layer

Status: accepted
Date: 2026-11-18

## Context

Agent Gateway is the platform's policy enforcement point for agent traffic. In Agent-to-Anywhere (egress)
mode, every outbound call goes through it: model, platform APIs, MCP tools. It checks the destination
against Agent Registry and an IAM unified access policy (default deny), and can apply Model Armor and
semantic governance policies. When this lab was written it required early-access enrollment, and:

- binding (or unbinding) an agent archives **all** of its existing revisions, irreversibly, and is only
  accepted while traffic is "always latest";
- all agents in a project and region must use the same egress gateway;
- hostnames match exactly, so every host variant the SDKs use (regional, global, `.mtls.`) must be
  registered, or calls fail with HTTP 498;
- binding an IAM access policy needs `constraints/iam.managed.disableAccessPolicyBindings` off in the org.

## Decision

The gateway is a separate, **opt-in** unit, and binding the agent to it is a separate, explicit step. The
gateway has to exist before the agent can bind to it, and the binding is disruptive:

1. `ENABLE_AGENT_GATEWAY=true` → `task gateway:up` creates the gateway, the IAP authorization (in
   **DRY_RUN**), Agent Registry entries for every destination host, and an egress access policy for the
   project's agent principal set (registered destinations only).
2. `task gateway:bind` switches traffic to "always latest", then sets
   `deployment_spec.agent_gateway_config.agent_to_anywhere_config` on the agent with the Agent Platform SDK
   (`lifecycle/release.py gateway`). It isn't a Terraform input, because the API refuses a `deployment_spec`
   on an engine without code, so the deploy tooling owns that block (ADR 0002).
3. Read the dry-run denials in the logs, register anything missing, then `AGENT_GATEWAY_ENFORCE=true` →
   `task gateway:up`.

The Model Armor floor setting (ADR 0005) already screens model and MCP traffic, so the lab is guarded
without the gateway. The gateway adds destination control.

## Consequences

- The lab works end to end without preview access.
- The `gcp/agent-gateway` module is validated against the provider schema only until it runs in an
  enrolled project. Its Terratest skips unless `AGENT_GATEWAY_PROJECT` is set.
- Unbinding later archives revisions again. Expect a fresh release after either change.
