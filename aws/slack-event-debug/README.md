# aws/slack-event-debug

A throwaway **Slack event tap**. It deploys one Python Lambda behind a public Lambda Function URL,
logs every incoming request (method, headers, raw body) to CloudWatch, and answers Slack's Events
API `url_verification` handshake by echoing the `challenge`. Point Slack's request URL at it to see
exactly what Slack POSTs — handy when a downstream integration (e.g. an Amazon Lex Slack channel)
isn't behaving and you need to inspect the payload. Spin it up, read the logs, tear it down.

> ⚠️ The endpoint is **public and unauthenticated**. It only logs
> and returns `200`, and it's meant to be short-lived. **Destroy it when you're done.**

## Architecture

```
Slack  ──HTTPS POST──▶  Lambda Function URL (auth: NONE)  ──▶  Lambda (Python 3.12)
                                                                  │
                                                                  ├─ logs full request ──▶ CloudWatch Logs
                                                                  └─ url_verification ──▶ echoes challenge
```

## Pinned module versions

| Unit             | Module       | Ref                 |
| ---------------- | ------------ | ------------------- |
| `infra/function` | `aws/lambda` | `aws-lambda-v0.3.0` |
****
## Prerequisites

- `tenv` (reads `.terraform-version` / `.terragrunt-version`), `terragrunt`, `aws` CLI, `zip`,
  `python3`, and [Task](https://taskfile.dev).
- AWS credentials for the target account.
- A globally-unique S3 bucket name for Terraform state.

## Run it

```bash
# 1. Seed local config, then edit .env (set AWS_REGION and a unique TF_STATE_BUCKET)
task init-env

# 2. One-time: create the S3 state bucket
task state-bootstrap

# 3. Build the zip and provision the Lambda + Function URL
task up

# 4. Grab the public endpoint and paste it into Slack's request URL field
task endpoint

# 5. Watch what Slack sends (Ctrl-C to stop)
task logs
```

When Slack saves the request URL it sends a `url_verification` request; you'll see it in the logs and
the handler echoes the challenge so Slack marks the URL verified. Every subsequent event is logged
and answered with `200 ok`.

## Tear it down

```bash
task down
```

## Not included (on purpose)

- **Slack request-signature verification** — skipped for a debug tap. Add the `X-Slack-Signature`
  check with a signing secret if this ever outlives its debug purpose.
