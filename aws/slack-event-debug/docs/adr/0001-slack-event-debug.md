# 0001 — Slack event tap: public Lambda Function URL, no API Gateway

- Status: accepted
- Date: 2026-07-12

## Context

While wiring an Amazon Lex bot to Slack, the integration isn't working and it's unclear what Slack
is actually POSTing to the configured endpoint. I need a way to *see the raw request* Slack sends —
headers and body — including the Events API `url_verification` handshake, without changing anything
about Lex.

This is a debug tool, not a durable lab: spin it up, point Slack at it, read the logs, tear it down.
The design goal is minimum moving parts and minimum cost, not production hardening.

## Decision

Deploy a single Python Lambda fronted by a **public Lambda Function URL** (`authorization_type =
NONE`), reusing the existing `modules/aws/lambda` module (`create_function_url = true`). The handler
logs the full request to CloudWatch and echoes the Slack `challenge` on `url_verification`.

Rejected alternatives:

- **API Gateway (REST/HTTP API) in front of Lambda** — more resources (API, stage, route,
  integration, permissions) for zero benefit here. A Function URL is one resource and gives an HTTPS
  endpoint directly.
- **ALB → Lambda target** — needs a VPC, subnets, listener, target group, and (for HTTPS) an ACM
  cert and DNS. Massively heavier than a debug tap warrants.
- **Slack request-signature verification** (`X-Slack-Signature` + signing secret) — deliberately
  skipped. It adds a secret to manage and code to maintain; for a short-lived tap that only logs and
  is destroyed after use, it's not worth it. Noted as the first thing to add if this ever becomes
  more than a debug tool.

## Consequences

- The endpoint is **unauthenticated** — anyone with the URL can invoke it and write log lines. That
  is acceptable *only* because it's short-lived and does nothing but log + return 200. **Destroy it
  when done** (`task slack-debug:down`); don't leave a public, unauthenticated URL running.
- Slack requires an unauthenticated webhook (it can't sign SigV4), so `NONE` auth is not just
  convenient but necessary.
- Logs land in `/aws/lambda/slack-event-debug` with 7-day retention, tailable via
  `task slack-debug:logs`.
