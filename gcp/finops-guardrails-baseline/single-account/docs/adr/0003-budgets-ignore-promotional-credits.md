# 0003 — Budgets subtract discounts and free tier, not promotional credits

- **Status:** accepted
- **Date:** 2026-10-05

## Context

A GCP budget compares a *spend* figure to its amount, and `credit_types_treatment` decides what that figure
is. There are three settings, and on a practice account two of them are wrong in opposite directions:

- **`INCLUDE_ALL_CREDITS`** (the default) — net spend, what you are invoiced. On a Free Trial account, or one
  running on promotional/event credit, net spend is $0 while real resources run. The zero-spend guard can
  never fire, which is precisely the situation it exists for: the credit runs out, and the first you hear of
  the forgotten cluster is a real bill.
- **`EXCLUDE_ALL_CREDITS`** — gross spend. Free tier is not "zero cost" in billing data: free-tier usage is
  recorded as a cost with an offsetting `FREE_TIER` credit. Excluding all credits makes an e2-micro or a
  few GB of Cloud Storage trip the one-cent guard, which teaches you to ignore it.

## Decision

Use `INCLUDE_SPECIFIED_CREDITS` on both budgets and subtract only credits that represent money you will
genuinely never pay:

```
DISCOUNT, FREE_TIER, SUSTAINED_USAGE_DISCOUNT, COMMITTED_USAGE_DISCOUNT,
COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE, SUBSCRIPTION_BENEFIT
```

`PROMOTION` is deliberately left out. The budgets therefore track *what this project would cost once the
promotional credit is gone*, which is the number that matters on a practice account.

`task show-spend` computes its net figure the same way (all credits except `PROMOTION`), so the export and the
budgets agree.

## Consequences

- On a Free Trial account you will get budget emails for spend you are not, today, paying for. That is the
  point; the alternative is silence until the credit expires.
- The list is explicit, so a credit type Google adds later is *not* subtracted until someone adds it here —
  the failure mode is an extra alert, not a missing one.
- The monthly budget overstates your invoice while promotional credit lasts. Read it as consumption, not as
  a bill forecast.
