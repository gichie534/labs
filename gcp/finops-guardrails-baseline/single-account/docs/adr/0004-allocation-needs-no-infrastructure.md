# 0004 — Allocation needs no infrastructure on GCP

- **Status:** accepted
- **Date:** 2026-10-05

## Context

The AWS lab has an `allocation` unit: it activates cost allocation tags (only after AWS has discovered them,
up to 24 hours after first use) and defines a cost category that buckets spend into `iac-managed`,
`shared-charges` and `untagged`. Both are needed because AWS billing data only carries tags you have
activated, and only from the moment of activation.

GCP works differently:

- **Labels are exported automatically.** Every resource label appears in the billing export's `labels` column
  (and project labels in `project.labels`) with no activation step and no discovery delay.
- **There is no cost-category resource.** Grouping is done at query time over the export.

The forward-only property still applies — a resource that was never labelled has no labels in history — so
*labelling* is still a day-one concern. It just is not an infrastructure one.

## Decision

- No allocation unit. The generated provider stamps `default_labels` (`lab`, `managed-by = terragrunt`) on
  every labelable resource, which is the GCP analogue of the AWS lab's `default_tags`.
- `task show-spend` reproduces the AWS cost category as a query:
  - `shared-charges` — rows whose `cost_type` is not `regular` (tax, adjustments, rounding). Like AWS's
    `RECORD_TYPE` rule, these can never carry a resource label.
  - `iac-managed` — `managed-by = terragrunt` in `labels`.
  - `unlabelled` — everything else. The interesting bucket, for the same reason as on AWS.

## Consequences

- One fewer unit and one fewer 24-hour wait. Allocation works from the first export row.
- The buckets live in a query, not in billing itself, so they do not appear in the console's billing reports.
  Filtering reports by label gives most of the same view.
- Budgets can filter on a single label pair (`label_filter` in `gcp/billing-budget`), so a per-team budget is
  possible later without any new allocation infrastructure.
- Not every resource type is labelable (budgets themselves, for example). Those show up as `unlabelled`
  regardless of how disciplined the IaC is; the number to watch is the trend, not zero.
