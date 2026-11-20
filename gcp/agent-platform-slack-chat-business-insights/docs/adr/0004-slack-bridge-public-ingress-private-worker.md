# 0004 — A thin Go Slack bridge: public ingress, Pub/Sub, private worker

Status: accepted
Date: 2026-11-18

## Context

Business users ask in Slack. The options:

- **The Gemini Enterprise app for Slack.** It's managed, but needs per-seat Gemini Enterprise licences and
  hides the plumbing this lab is meant to teach: session mapping and authenticating to Agent Runtime.
- **Socket Mode.** It needs a long-lived WebSocket, so an always-on instance.
- **Events API on Cloud Run** (chosen). Slack requires a 200 within **3 seconds** and retries otherwise. An
  agent turn with several tool calls takes 10–90 seconds.

## Decision

One Go binary, two Cloud Run services:

```
Slack ──HTTPS──▶ bi-slack-ingress (public, invoker IAM check off)
                   verify HMAC signature, drop retries/bots, queue, 200
                       │ Pub/Sub topic bi-slack-events
                       ▼ push + OIDC token for bi-slack-push
                 bi-slack-worker (private, only bi-slack-push may invoke)
                   session = Slack thread, user = Slack user
                   :query async_get/create_session, :streamQuery async_stream_query
                   reply in thread
```

- **Least privilege by splitting.** The internet-facing ingress may only read the signing secret and publish
  to one topic. It can't call the agent or read the bot token. The worker can do both, but isn't reachable
  from the internet: Cloud Run enforces that only the push identity invokes it.
- **No `allUsers`.** The ingress uses `invoker_iam_disabled`. It works under domain-restricted sharing, and
  the application authenticates each request with Slack's signature instead.
- **Sessions map to threads.** The session ID is derived from team, channel and thread
  (`s-t…-c…-<ts>`, within the Sessions API's 63-character `[a-z0-9-]` rule), so a follow-up in the thread
  has context. The user ID is derived from the Slack user, which is also Memory Bank's scope, so
  preferences follow the person across threads.
- **No double answers.** Slack retries are dropped at the ingress. The worker acknowledges every message,
  even after an agent error (it posts one apology), because a Pub/Sub redelivery would re-run the agent and
  post a second answer.
- **Secrets are read at runtime** with a 10-minute cache instead of env injection. Services can be created
  before the secrets have versions, and rotating means re-running `task slack:secrets`.
- **Terraform owns the services' configuration; the pipeline owns the image** (module `gcp/cloud-run-service`
  ignores the image after creation).

## Consequences

- The bridge calls the **engine**, so the traffic split decides which revision answers each Slack message.
  A canary is visible to Slack users.
- If a worker instance dies mid-turn, Pub/Sub redelivers after the 600-second ack deadline, and a duplicate
  answer is possible. That's acceptable for a lab.
- Everyone in an allowed channel uses the same agent permissions (ADR 0003).
