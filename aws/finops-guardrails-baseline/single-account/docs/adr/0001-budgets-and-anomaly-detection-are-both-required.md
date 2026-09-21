# 0001 — Budgets and anomaly detection are both required, not alternatives

- **Status:** accepted
- **Date:** 2026-09-17

## Context

The obvious way to build cost guardrails is to set a budget and stop. Both AWS Budgets and Cost Anomaly
Detection notify you about spend, they overlap in the console, and one of them is enough to tick the box
on any "did you set up cost controls" checklist.

They are not substitutes, and understanding why is most of the value of this lab.

**A budget compares spend to a number you chose.** That makes it good at exactly one thing: telling you
when spend passes a limit you decided in advance. It has two structural blind spots. First, AWS refreshes
billing data [at least once a day](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html),
so the alert arrives after the money is spent — it is a guardrail, not a circuit breaker. Second, and more
important, it knows nothing about the *shape* of your spend. A service that quietly costs ten times what
it did last week is completely invisible to a monthly budget as long as the total stays under the limit.
That is the common case, not an edge case: most cost incidents are a single service or resource
misbehaving inside an otherwise normal month.

**Anomaly detection compares spend to a model of your own history.** It catches precisely the case the
budget misses, needs no threshold decided in advance, and costs nothing. Its blind spot is the mirror
image: it has no opinion about whether your *total* is affordable. A steady, deliberate, entirely
unexceptional $500/month is not an anomaly, even if your limit is $50.

## Decision

Provision both, wired to the same notification channel.

Also provision both *shapes* of anomaly subscription: an `IMMEDIATE` one over SNS for reaction, and a
`DAILY` email digest for awareness. This is partly forced — AWS ties the channel to the frequency, with
`IMMEDIATE` delivered only via SNS and summaries only by email — but the split is right anyway. Alerts
you must act on and alerts you should merely read want different thresholds; the digest here sits at
twice the immediate floor.

Anomaly thresholds combine an absolute floor with a percentage using `OR`. Each alone is wrong in a
predictable direction: an absolute floor sleeps through a steady 30% overspend on a large bill, and a
percentage fires on a $2 service that tripled.

## Consequences

- Two systems to understand instead of one, and two ways to be woken up.
- Both are free at this scale (budgets are free for the first two per account; anomaly detection has no
  charge), so the cost of the redundancy is conceptual, not financial.
- Neither can stop spend. Enforcement means budget actions, which in a single account can only attach an
  IAM policy or stop EC2/RDS instances; the version with real teeth attaches an SCP and requires AWS
  Organizations. That is deliberately out of scope here and belongs in the multi-account lab.
- The forecast threshold stays quiet on a brand-new account, because AWS cannot project a period it has no
  baseline for. Same for the anomaly model. A guardrail baseline is worth less in week one than in month
  six, which is an argument for standing it up early rather than a reason to wait.
