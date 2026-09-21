# 0003 — The cost and usage export belongs in the baseline

- **Status:** accepted
- **Date:** 2026-09-17

## Context

A CUR 2.0 export is the only thing in this lab with an ongoing charge, and the only thing that needs a
second globally-unique bucket name in `.env`. It is also the piece nobody asks for when they say "set up
budget guardrails". The tempting call is to leave it out of a baseline and add it when somebody actually
wants a cost report.

Two facts argue the other way.

**Alerts cannot answer the question they raise.** Budgets and anomaly detection both work on aggregates.
They tell you *that* spend moved — an account crossed a limit, a service deviated from its baseline. The
immediate next question is always *which resource*, and neither can answer it. Cost Explorer helps you
browse, but its API is billed per request, its granularity and retention are limited, and you cannot join
it against anything of your own. Hourly, resource-level line items in a bucket you own is the dataset that
answers the follow-up, and it is what every serious FinOps practice is built on.

**It is not retroactive.** This is the decisive part. Turn on a budget today and it works today. Turn on an
export today and you get data from today forward; the past is simply gone. Cost allocation tag activation
has the same property. So the cost of adding it late is not effort — it is a permanent hole in the history
across exactly the period you will most want to explain.

That combination is what makes something a *foundation* concern rather than a feature: it is a decision
that cannot be deferred without loss.

## Decision

Include the export in the default path, at the most granular setting the table offers — hourly, with
resource IDs, in Parquet — and pair it with a lifecycle rule on the destination bucket.

Granularity is asymmetric in the same way retroactivity is: detail you did not capture cannot be
reconstructed, whereas an export that turns out to be too large is one lifecycle rule away from being
fine. So the default errs toward capturing more, and the bucket expires objects after a year (tiering to
Standard-IA at 30 days).

Overwrite mode is `OVERWRITE_REPORT`, which keeps one copy per period rather than a new version on every
refresh.

## Consequences

- The lab is no longer strictly free. It is standard S3 rates for a few MB a month on a quiet account —
  cents — but "free" and "nearly free" are different claims and the README says which one applies.
- `.env` needs a second unique bucket name before `task up` will work.
- Nothing appears in the bucket for roughly 24 hours. An empty bucket shortly after apply is expected;
  `task verify` reports the object count with that caveat attached rather than failing on it.
- Anyone who genuinely wants a zero-cost run can skip the two units
  (`terragrunt run --all apply --queue-exclude-dir export-bucket --queue-exclude-dir data-export`) and
  accept that they are giving up the one thing they cannot backfill.
