# aws/finops-guardrails-baseline/single-account

The cost guardrails you want in place **before** you need them, in one standalone AWS account: spend
limits, alerts you will actually receive, anomaly detection, allocation metadata, and the line-item export
that lets you answer "which resource?" after an alert fires.

This is the FinOps *foundation*, deliberately free of anything workload-specific — no rightsizing, no
Compute Optimizer, no Savings Plans or spot-versus-on-demand analysis. Those are optimisation decisions
that depend on what you run. Everything here is true of any account regardless of what is in it, and most
of it is either one-way or worth more the earlier it exists.

The companion lab `aws/finops-guardrails-baseline/multi-account` (next) does the same job at the
Organizations level, where the payer becomes a control plane and budgets gain real teeth via SCPs.

## Architecture

```
                            ┌──────────────────────────────┐
                            │  SNS topic: finops-baseline  │
             ┌─────────────▶│  policy allows both billing  │──▶ email (must be confirmed!)
             │              │  service principals          │
             │              └──────────────────────────────┘
             │                             ▲
   ┌─────────┴──────────┐   ┌──────────────┴───────────────┐
   │ AWS Budgets        │   │ Cost Anomaly Detection       │
   │ (one unit each)    │   │ • IMMEDIATE  → SNS           │
   │ • monthly limit    │   │ • DAILY      → email         │
   │   50/80/100% actual│   │   (AWS ties channel to       │
   │   100% forecast    │   │    frequency, not a choice)  │
   │ • zero-spend guard │   │         ▲                    │
   │   ($0.01 absolute) │   │         │ subscriptions only │
   └────────────────────┘   └─────────┼────────────────────┘
        compares spend to             │ AWS-managed "AWS services"
        a number you chose            └ monitor (1 per account,
                                        created by AWS, adopted
                                        here — see ADR 0004)

   ┌────────────────────────┐   ┌───────────────────────────────────────────┐
   │ Cost category          │   │ CUR 2.0 export (hourly, resource-level)   │
   │ iac-managed            │   │  Data Exports ──▶ S3 bucket (us-east-1)   │
   │ shared-charges         │   │  • module owns the delivery bucket policy │
   │ untagged   (default)   │   │  • lifecycle: IA at 30d, expire at 365d   │
   └────────────────────────┘   └───────────────────────────────────────────┘
        makes a number              answers the question an alert raises
        attributable                (and cannot be backfilled)
```

Everything is in `us-east-1` because every billing API is global via that endpoint — see
[ADR 0002](docs/adr/0002-region-is-not-parameterised.md).

## What each unit is for

| Unit                      | What it creates                           | Why it is in a *baseline*                                                                                                                                                                         |
| ------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra/alerts`            | SNS topic + email subscription            | A guardrail nobody hears about is not a guardrail. Both billing services publish as their own service principal, so the topic policy must name them — miss it and alerts are denied **silently**. |
| `infra/budget-monthly`    | Monthly cost budget                       | The limit you chose: 50/80/100% of actual spend plus 100% of AWS's forecast for the month.                                                                                                        |
| `infra/budget-zero-spend` | Zero-spend guard ($0.01 absolute)         | The case where you thought the account was empty and it is not. Separate unit because it is set once and never edited, unlike the limit above. Two budgets is also exactly the free allowance.    |
| `infra/lookups`           | Nothing — reads account state             | Finds the AWS-managed anomaly monitor your account already has. Lab-local glue, so it is sourced from a local path, not the modules repo.                                                         |
| `infra/anomaly-detection` | 2 subscriptions on that monitor           | Catches what a budget structurally cannot: one service costing 10x last week while the total stays under the limit. Free.                                                                         |
| `infra/allocation`        | Cost category (+ optional tag activation) | Turns "the account overspent" into "this overspent". Not retroactive.                                                                                                                             |
| `infra/export-bucket`     | Lifecycle-managed S3 bucket               | Hourly cost data never stops arriving; "keep forever" is a cost decision nobody makes on purpose.                                                                                                 |
| `infra/data-export`       | CUR 2.0 hourly export                     | The only thing that can tell you *which resource*. Also the only thing here that cannot be backfilled.                                                                                            |

## Pinned module versions

All infrastructure comes from [`gichie534/infrastructure-catalog`](https://github.com/gichie534/infrastructure-catalog)
by pinned tag. Nothing reusable is defined in this lab.

| Module                       | Tag                                 |
| ---------------------------- | ----------------------------------- |
| `aws/sns-topic`              | `aws-sns-topic-v0.1.0`              |
| `aws/budget`                 | `aws-budget-v0.1.0`                 |
| `aws/cost-anomaly-detection` | `aws-cost-anomaly-detection-v0.2.0` |
| `aws/cost-allocation`        | `aws-cost-allocation-v0.1.0`        |
| `aws/s3-bucket`              | `aws-s3-bucket-v0.3.0`              |
| `aws/cost-data-export`       | `aws-cost-data-export-v0.2.0`       |

Pinned toolchain: Terraform `1.15.6`, Terragrunt `1.0.7` (read by [tenv](https://github.com/tofuutils/tenv)).

## Cost

Budgets are free for the first two per account. Cost Anomaly Detection is free. Cost categories and tag
activation are free. The Data Exports service is free. SNS email is effectively free.

The one ongoing charge is **S3 storage for the export** — a few MB a month on a quiet account, tiered to
Standard-IA after 30 days and expired after a year. Call it cents. The `show-spend` task uses the Cost
Explorer API, which is billed at $0.01 per request.

## Run it

```bash
cd aws/finops-guardrails-baseline/single-account

task init-env          # create .env from the template
$EDITOR .env           # TF_STATE_BUCKET, FINOPS_ALERT_EMAIL, FINOPS_EXPORT_BUCKET are required

task fmt               # format HCL              (cost-free)
task validate          # validate every unit     (cost-free)
task plan              # see what would change   (cost-free)

task state-bootstrap   # once: create the S3 state bucket
task up                # provision everything

# ⚠️ Now go and click the link in the AWS confirmation email. Until you do, every alert
#    in this lab is delivered to nobody.

task verify            # assert the guardrails exist AND that the channel is confirmed
task test-alert        # publish a test message — proves delivery without waiting for spend
task show-spend        # month-to-date by service, and by this lab's cost category

task down              # destroy everything
```

## What to notice

- **`task verify` checks the subscription state, not just resource existence.** A successful `apply` and a
  working alert channel are different things: Terraform cannot click a confirmation link, so the honest
  end state of `up` is a topic with a `PendingConfirmation` subscriber. This is the most common way a
  cost-alerting setup looks finished and is mute.
- **The export bucket is empty for about 24 hours.** Not broken. First delivery takes roughly a day, then
  refreshes land at least daily.
- **`FINOPS_COST_ALLOCATION_TAG_KEYS` starts empty on purpose.** AWS only accepts activation for tag keys
  it has *already discovered* on a real resource, which takes up to 24 hours after the tag first appears —
  then up to another 24 for activation to take effect. Listing a key too early fails the apply. Run the
  lab, wait a day, set `Lab,ManagedBy`, re-apply.
- **The cost category's `untagged` bucket is the interesting number.** On a practice account it is mostly
  things clicked together in the console months ago. Unnamed, that spend is invisible; named, it is a
  number you can watch shrink.
- **Forecast thresholds and the anomaly model both need history.** Neither says much in week one. That is
  an argument for standing this up early, not for waiting.

## Single account vs Organizations

Worth knowing what this lab *cannot* teach, because it is the reason there is a second one:

- **Enforcement.** A budget action in a single account can attach an IAM policy or stop EC2/RDS instances.
  The version with teeth attaches an **SCP**, which requires Organizations. No budget here can actually
  stop spend.
- **Cross-account visibility.** Anomaly monitors on linked account, cost allocation tag, or cost category
  can only be created from a management account. A standalone account gets the `SERVICE` dimension.
- **Account as an allocation dimension.** Tags can be changed or forgotten; an account ID cannot. In an
  org the account boundary becomes the tamper-proof unit of allocation, which changes the whole shape of
  chargeback.
- **Pooled economics.** Consolidated billing shares RI/Savings Plans coverage and volume tiering across
  accounts, so "who gets the credit" becomes a real question — and blended vs unblended cost starts to
  matter when reading any of these numbers.

## Decisions

- [ADR 0001 — Budgets and anomaly detection are both required, not alternatives](docs/adr/0001-budgets-and-anomaly-detection-are-both-required.md)
- [ADR 0002 — The region is not parameterised](docs/adr/0002-region-is-not-parameterised.md)
- [ADR 0003 — The cost and usage export belongs in the baseline](docs/adr/0003-the-cost-export-belongs-in-the-baseline.md)
- [ADR 0004 — Adopt the AWS-managed anomaly monitor rather than creating one](docs/adr/0004-adopt-the-aws-managed-anomaly-monitor.md)
