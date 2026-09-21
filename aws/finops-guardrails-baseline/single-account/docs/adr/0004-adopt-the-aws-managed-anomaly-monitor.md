# 0004 — Adopt the AWS-managed anomaly monitor rather than creating one

- **Status:** accepted
- **Date:** 2026-09-21

## Context

The first version of this lab created its own anomaly monitor:

```hcl
monitors = {
  "finops-baseline-services" = {
    monitor_type      = "DIMENSIONAL"
    monitor_dimension = "SERVICE"
  }
}
```

`apply` failed:

```
Error: creating Cost Explorer Anomaly Monitor (finops-baseline-services):
api error ValidationException: Limit exceeded on dimensional spend monitor creation
```

The [quota](https://docs.aws.amazon.com/cost-management/latest/userguide/management-limits.html) is **one
AWS-managed monitor for AWS services per account**, and AWS creates that monitor for you when Cost Anomaly
Detection is enabled. So the account already had one. This was never going to work on any account that had
ever looked at Cost Anomaly Detection — which, given AWS enables it by default, is effectively all of them.

It is worth being precise about the error, because the wording invites the wrong fix. "Limit exceeded"
sounds like something a quota increase solves. It is not: the limit is 1 and it is not adjustable. The
error is telling you the resource already exists and is not yours to create.

## Decision

Split ownership along the line AWS already draws:

- **The monitor is account infrastructure AWS owns.** We read its ARN and leave it alone. `task down` does
  not delete it, which is correct — we did not create it.
- **The alerting policy is ours.** Which thresholds, which channels, which recipients, how often. That is
  what the lab creates, and it is the part that actually encodes a decision.

The `aws/cost-anomaly-detection` module gained `subscriptions[*].monitor_arns` (released as v0.2.0) so a
subscription can attach to a monitor the module does not manage. A lab-local `infra/lookups` unit discovers
the ARN, because the AWS provider has no data source for anomaly monitors — it shells out to
`aws ce get-anomaly-monitors` through the `external` provider.

If the lookup finds nothing, the account has never enabled Cost Anomaly Detection and there is no monitor
to adopt. In that one case the lab creates the monitor itself. Both branches live in the unit rather than
being a manual decision, so a fresh account and an established one behave the same from the operator's side.

## Consequences

- One more unit, and a dependency on the `external` provider plus the AWS CLI. The CLI was already required
  by the Taskfile (`verify`, `test-alert`, `show-spend`), so the new cost is the provider.
- `infra/lookups` runs a shell command at plan time, which means `task plan` needs credentials. It already
  did, so nothing changes in practice — but `terraform validate` stays cost-free and credential-free
  because `validate` does not read data sources.
- The monitor the lab alerts on is not in Terraform state, so its configuration is not reproducible from
  this repo. That is the honest consequence of not owning it, and the alternative — importing an
  AWS-managed resource in order to manage a name change that would force replacement — trades a small
  documentation gap for a guaranteed apply failure.
- The module's default `monitor_type` is now `CUSTOM` rather than `DIMENSIONAL`, so the failure mode above
  is opt-in rather than the path of least resistance.

## What this suggests about the multi-account lab

The same quota exists at the org level, with one extra managed monitor allowed in the management account
for linked account / cost allocation tag / cost category. That is 2 managed monitors total for an entire
organisation, so any per-team or per-account anomaly alerting has to be built from **customer-managed**
monitors (500 per management account, 10 values each) or from subscription-level filtering — not by giving
each account its own managed monitor. Worth designing for from the start there.
