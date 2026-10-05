# 0002 — Terraform owns the export dataset; the export is enabled by hand

- **Status:** accepted
- **Date:** 2026-10-05

## Context

The AWS lab puts the CUR 2.0 export in the baseline because budgets and anomaly detection only say *that*
spend moved, never *which resource* moved it, and because an export is not retroactive
([its ADR 0003](../../../../aws/finops-guardrails-baseline/single-account/docs/adr/0003-the-cost-export-belongs-in-the-baseline.md)).
The GCP equivalent is the **detailed usage cost** export to BigQuery, and the reasoning is the same.

Two GCP facts change the design:

1. **The export cannot be enabled through any API.** It is a billing-account setting in the console
   (*Billing → Billing export → BigQuery export*). There is no Terraform resource for it.
2. **The dataset's location decides how much history you get.** Per
   [Google's setup guide](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup), a
   multi-region (`US`/`EU`) dataset receives the current and previous month retroactively when the export is
   first enabled; a regional dataset gets data from the day of enablement only. Location is immutable.

Google also warns that export tables which expire, or are deleted, cannot be backfilled; and when the export
is enabled it adds `billing-export-bigquery@system.gserviceaccount.com` to the dataset as an owner.

## Decision

- Terraform creates the dataset (`infra/export-dataset`) and owns the one-way choices: **US multi-region**
  by default (overridable to EU via `FINOPS_EXPORT_DATASET_LOCATION`), **no table expiration**.
- The `gcp/bigquery-dataset` module manages access **additively only** and ignores drift on `access`, so it
  can never remove Google's export account.
- `task up` ends by printing the console step; `task verify` WARNs until an export table exists. It cannot
  FAIL, because "not enabled" and "enabled an hour ago" look identical from outside.
- Lab-only: `delete_contents_on_destroy = true`, so `task down` cleans up. Any dataset you mean to keep
  should leave the module default (`false`).

## Consequences

- One manual step in an otherwise one-command lab. It is the step with the least reversible outcome, so it is
  printed, not buried.
- The location knob exists, but its only sensible values are the multi-regions; the `.env.example` says so.
- `task down` leaves the console export pointed at a dataset that no longer exists. The task prints a
  reminder to disable it.
- Retention is unbounded. BigQuery long-term storage is cheap and the guidance is explicit about not expiring
  export tables, so the lab does not mirror the AWS bucket's 365-day lifecycle rule.
