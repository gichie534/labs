# 0002 — The region is not parameterised

- **Status:** accepted
- **Date:** 2026-09-17

## Context

Every other lab in this repo reads `AWS_REGION` from `.env` and passes it through `root.hcl` into the
generated provider. Consistency would suggest doing the same here.

It would be wrong. Every service this lab touches is global, and two of them are reachable only through
their `us-east-1` endpoints:

- **Cost Explorer** (`ce`) — cost categories, cost allocation tags, anomaly monitors and subscriptions.
- **AWS Data Exports** (`bcm-data-exports`) — the CUR 2.0 export. The `us-east-1` in the required bucket
  policy's `aws:SourceArn` is not a choice, it is the service's only home.
- **AWS Budgets** is regionless; the endpoint you call is irrelevant.

A region input here would therefore be a setting with exactly two possible effects: no effect, or
breaking the lab.

## Decision

Pin the whole lab to `us-east-1` in `root.hcl` and do not expose a region variable. That covers the
provider, the Terraform state bucket, and the cost export bucket.

## Consequences

- One fewer knob, and one fewer way to produce a confusing failure. Someone in `eu-west-1` who set
  `AWS_REGION` out of habit would get errors from the Cost Explorer API that say nothing about regions.
- The export bucket lives in `us-east-1` even though it does not have to — the export's destination can be
  any region. Splitting the bucket's region from the control plane's would be more faithful to how AWS
  works, but it buys nothing here and costs a variable that needs explaining. The
  `aws/cost-data-export` module keeps `s3_region` as an input, so a consumer that cares can still do it.
- This is lab-specific reasoning, not a repo-wide rule. A lab that provisions workloads should absolutely
  parameterise its region; the reason this one does not is that it provisions no workloads.
