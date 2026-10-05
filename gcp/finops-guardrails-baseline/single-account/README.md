# gcp/finops-guardrails-baseline/single-account

The cost guardrails you want in place **before** you need them, on a single GCP **billing account** with no
Organization required. The budgets watch one project today; the export and anomaly detection already cover
every project on the billing account, because on GCP that is where they live. You get:
a spend limit, a zero-spend tripwire, an alert channel that reaches you, a machine-readable budget feed, and
the destination for the line-item export that answers "which resource?" after an alert fires.

The GCP sibling of [`aws/finops-guardrails-baseline/single-account`](../../../aws/finops-guardrails-baseline/single-account/).
Same intent, same unit shape where GCP allows it — and the places where it does not are most of what this
lab teaches. Two of the AWS lab's units (anomaly detection, the export itself) have **no API on GCP**, and
one (allocation) needs **no infrastructure** at all.

## Architecture

```
                         ┌───────────────────────────────────────────┐
                         │ Billing account (budgets live HERE,       │
                         │ not in the project)                       │
                         │                                           │
                         │  budget-monthly       budget-zero-spend   │
                         │  50/80/100% current   1% of $1            │
                         │  100% forecast        (one cent)          │
                         │  filter: projects/<NUMBER>                │
                         │  credits: subtract discounts + free tier, │
                         │           NOT promotional (ADR 0003)      │
                         └──────┬──────────────────────┬─────────────┘
              threshold crossed │                      │ status, several times a day
                                ▼                      ▼
     ┌──────────────────────────────┐   ┌───────────────────────────────────────┐
     │ Monitoring email channel     │   │ Pub/Sub: finops-budget-updates        │
     │ (live at once, no confirm)   │   │ publisher: billing-budget-alert@…     │
     │ + billing admins by default  │   │ ──▶ pull sub (7d, never expires)      │
     └──────────────────────────────┘   │     read by `task show-spend`         │
                                        └───────────────────────────────────────┘

     ┌───────────────────────────────────────┐   ┌────────────────────────────────┐
     │ BigQuery dataset billing_export (US)  │◀──│ Billing export (detailed)      │
     │ no expiration, additive access only   │   │ CONSOLE-ONLY — no API (ADR 2)  │
     └───────────────────────────────────────┘   └────────────────────────────────┘

     ┌───────────────────────────────────────┐
     │ Cost anomaly detection                │   on by default for every project,
     │ CONSOLE-ONLY — no API (ADR 0001)      │   thresholds/recipients set by hand
     └───────────────────────────────────────┘
```

## What each unit is for

| Unit                      | What it creates                   | Why it is in a *baseline*                                                                                                                                                                        |
| ------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `infra/apis`              | Enables 5 APIs                    | Budgets, Monitoring, Pub/Sub, BigQuery, Cloud Billing. Never disabled on destroy.                                                                                                                |
| `infra/alert-channels`    | Monitoring email channel          | Where a crossed threshold lands. No confirmation step (unlike SNS), so a typo is silent — `task verify` prints the address back.                                                                 |
| `infra/budget-topic`      | Pub/Sub topic + pull subscription | The only programmatic hook GCP offers. Billing publishes as its own service account, so the topic grant is the GCP twin of the AWS lab's SNS policy: miss it and publishes are refused silently. |
| `infra/budget-monthly`    | Monthly budget on this project    | The limit you chose: 50/80/100% of current spend plus 100% of forecast.                                                                                                                          |
| `infra/budget-zero-spend` | 1% of $1 budget on this project   | The project you thought was empty. Its credit treatment is the subtle part (ADR 0003).                                                                                                           |
| `infra/export-dataset`    | Multi-region BigQuery dataset     | Where the detailed export lands. Location and expiration are one-way decisions made here; the export itself is switched on in the console.                                                       |

## Pinned module versions

All infrastructure comes from [`gichie534/infrastructure-catalog`](https://github.com/gichie534/infrastructure-catalog)
by pinned tag. Nothing reusable is defined in this lab.

| Module                      | Tag                                |
| --------------------------- | ---------------------------------- |
| `gcp/project-services`      | `gcp-project-services-v0.1.0`      |
| `gcp/notification-channels` | `gcp-notification-channels-v0.1.0` |
| `gcp/pubsub-topic`          | `gcp-pubsub-topic-v0.1.0`          |
| `gcp/billing-budget`        | `gcp-billing-budget-v0.1.0`        |
| `gcp/bigquery-dataset`      | `gcp-bigquery-dataset-v0.1.0`      |

Pinned toolchain: Terraform `1.16.4`, Terragrunt `1.0.7` (read by [tenv](https://github.com/tofuutils/tenv)).

## Permissions

- `roles/billing.costsManager` (or `roles/billing.admin`) **on the billing account** — budgets are
  billing-account resources; project Owner is not enough.
- Owner/Editor on the project (APIs, channel, topic, dataset).
- Enabling the export in the console additionally needs BigQuery User on the project.

The generated provider sets `billing_project` + `user_project_override = true`. With user ADC the Budgets API
returns a 403 without a quota project, and the error mentions credentials rather than the missing setting.

## Cost

Budgets, notification channels and anomaly detection are free. The topic and a few KB of budget messages a
day sit inside the Pub/Sub free tier. The one ongoing charge is **BigQuery storage for the export** — MBs a
month on a quiet project, billed at standard (then long-term) storage rates. `task show-spend` runs two small
queries against it, well inside the monthly free query allowance.

## Run it

```bash
cd gcp/finops-guardrails-baseline/single-account

task init-env          # create .env from the template
$EDITOR .env           # GCP_PROJECT, GCP_PROJECT_NUMBER, GCP_BILLING_ACCOUNT, TF_STATE_BUCKET, FINOPS_ALERT_EMAIL

gcloud auth application-default login

task init-state        # once: create the GCS state bucket
task fmt               # format HCL              (cost-free)
task validate          # validate every unit     (cost-free; needs the state bucket)
task plan              # see what would change   (cost-free)

task up                # preflight checks, then provision everything

# Now the one manual step `up` prints: Billing → Billing export → BigQuery export → Detailed usage cost →
# project = $GCP_PROJECT, dataset = billing_export. There is no API for it.
# And once: Billing → Anomalies → Manage anomalies — review thresholds and recipients (ADR 0001).

task verify            # assert the guardrails exist and are wired to a live channel
task test-alert        # round-trip a message through the budget topic
task show-spend        # latest budget status from the feed + month-to-date by service and by label bucket

task down              # destroy everything, then disable the export in the console
```

`task up` refuses to run while `.env` still holds a `REPLACE_WITH` value, and checks two mistakes that
otherwise fail halfway through an apply: a `GCP_PROJECT_NUMBER` that is not this project's, and a
`GCP_BILLING_ACCOUNT` that is not the one paying for it.

## What to notice

- **Budgets belong to the billing account.** The project is only a filter, and only by project *number*.
  Without the filter, a budget on a shared billing account silently measures every project it pays for.
- **There is no confirmation link, and that cuts both ways.** The AWS lab's classic failure — a topic with a
  `PendingConfirmation` subscriber — cannot happen here. A mistyped address can, and nothing will tell you.
- **Pub/Sub is a feed, not an alert.** Billing publishes every budget's current spend several times a day,
  threshold or not. That is why `show-spend` reads it and why it is the hook for any automation, and why
  nobody should subscribe a phone to it.
- **Credits decide whether the zero-spend guard can ever fire.** With GCP's default treatment, a project
  burning Free Trial credit reports $0. With *all* credits excluded, genuinely free usage trips it, because
  free tier is billed as a cost with an offsetting credit. See ADR 0003.
- **The export dataset is US multi-region on purpose.** Only multi-region datasets receive the current and
  previous month when the export is first enabled. A regional dataset starts from the day you click Save.
- **Labels need no activation.** The AWS lab waits 24 h for tag discovery and then activates keys. GCP
  exports every label automatically; `show-spend` splits spend into `iac-managed` / `shared-charges` /
  `unlabelled` with a query instead of a cost category. See ADR 0004.

## Billing account vs organization

Unlike AWS, the number of projects is not what changes the setup: budgets, anomaly settings and the export
already belong to the billing account. What changes it is having an Organization, and that is what an
`organization` sibling would cover:

- **Enforcement.** Nothing here stops spend. On GCP that means a function on the budget topic that detaches
  billing (destructive: it stops *everything* in the project), or Spend Caps (preview, console-only, a few
  AI/serverless services). Both are out of scope for a baseline.
- **Folder/org scoping.** Budgets can filter on `resource_ancestors` (folders, organizations), which turns
  the folder hierarchy into the unit of allocation — the GCP analogue of the AWS account boundary.
- **Org policy interactions.** `iam.allowedPolicyMemberDomains` blocks the Google service-account grants this
  lab relies on (budget publisher, export writer) unless the project is exempted.

## Decisions

- [ADR 0001 — Anomaly detection is a guardrail this lab cannot own](docs/adr/0001-anomaly-detection-is-not-managed-by-terraform.md)
- [ADR 0002 — Terraform owns the export dataset; the export is enabled by hand](docs/adr/0002-export-dataset-in-terraform-export-by-hand.md)
- [ADR 0003 — Budgets subtract discounts and free tier, not promotional credits](docs/adr/0003-budgets-ignore-promotional-credits.md)
- [ADR 0004 — Allocation needs no infrastructure on GCP](docs/adr/0004-allocation-needs-no-infrastructure.md)
