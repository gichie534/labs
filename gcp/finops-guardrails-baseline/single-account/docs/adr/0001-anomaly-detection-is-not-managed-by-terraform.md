# 0001 — Anomaly detection is a guardrail this lab cannot own

- **Status:** accepted
- **Date:** 2026-10-05

## Context

The AWS sibling of this lab rests on one argument
([its ADR 0001](../../../../aws/finops-guardrails-baseline/single-account/docs/adr/0001-budgets-and-anomaly-detection-are-both-required.md)):
budgets and anomaly detection are not alternatives. A budget compares spend to a number you chose; anomaly
detection compares it to your own history, and catches a service costing ten times last week's while the
monthly total sits under the limit. That argument holds on GCP unchanged.

What does not carry over is the mechanics. Google Cloud's
[Cost Anomaly Detection](https://cloud.google.com/billing/docs/how-to/manage-anomalies) is:

- **On by default** for every project on every billing account since it went GA. There is nothing to create.
- **Configured only in the console.** The cost-impact and deviation thresholds and the notification
  recipients (billing admins, Essential Contacts, project owners, a Pub/Sub topic) are billing-account-wide
  settings under *Billing → Anomalies → Manage anomalies*. There is no public API to read or write them, and
  the Terraform provider has no resource for them.
- **Already notifying someone.** By default billing admins get an email for every individual anomaly.

## Decision

Treat anomaly detection as part of the baseline but not part of the Terraform: document a one-time console
review (thresholds, recipients, optionally the lab's Pub/Sub topic) and have `task verify` report it as INFO
with a link, rather than PASS or FAIL.

Do not script around the gap (browser automation, undocumented endpoints). A guardrail that depends on an
unsupported interface fails at the worst moment, and quietly.

## Consequences

- The lab cannot prove anomaly alerting is configured. That is a real hole in `task verify`, stated as one.
- Defaults are reasonable: on a personal billing account the billing admin is you, so anomaly emails already
  reach the right person with no setup.
- Thresholds are billing-account-wide, not per project. You cannot set a tighter bar for this project
  alone — which is one more reason the zero-spend budget exists.
- If Google publishes an API or provider resource later, this ADR is superseded by a new unit, not by
  editing this one.
