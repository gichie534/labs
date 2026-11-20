# Slack setup: app, bot and channel

How to connect the lab to your **test Slack workspace**: create the Slack app from the lab's manifest, store
its credentials, verify the events URL, and add the bot to a channel. Takes about 10 minutes.

```
Slack ──(Events API: app_mention, message.im)──▶ bi-slack-ingress ──▶ Pub/Sub ──▶ bi-slack-worker ──▶ agent
  ▲                                                                                     │
  └──────────────────────── chat.postMessage (reply in thread) ─────────────────────────┘
```

## 0. Before you start

You need the bridge running with its real image. The bootstrap "hello" container can't answer Slack's
verification request.

```bash
task up          # infra, including the two Cloud Run services and the empty Slack secrets
task deploy      # agent revision + Slack bridge image
task slack:check # prints the Request URL and checks the ingress answers /health
```

`slack:check` should print `ingress healthy`. If it says the hello container is still serving, run
`task deploy:bridge`.

You also need to be allowed to create apps in the workspace. In your own test workspace you are; in a company
workspace an admin may have to approve the install.

## 1. Create the Slack app from the manifest

```bash
task slack:manifest
```

This prints a YAML manifest with this lab's ingress URL filled in (`https://bi-slack-ingress-…run.app/slack/events`).

1. Open <https://api.slack.com/apps> → **Create New App** → **From a manifest**.
2. Pick your test workspace → **Next**.
3. Select the **YAML** tab, replace the example with the printed manifest → **Next** → **Create**.

Slack may warn that the **Request URL isn't verified**. That's expected: Slack signs the verification request
with the new app's signing secret, which the ingress doesn't have yet. You'll verify it in step 4.

What the manifest asks for, and why:

| Setting | Value | Why |
|---|---|---|
| Bot scope `app_mentions:read` | | receive `@business-insights …` in channels the bot is in |
| Bot scope `chat:write` | | post the answer in the thread |
| Bot scopes `im:history`, `im:read` | | receive direct messages to the bot |
| Bot scope `reactions:write` | | the ⏳ reaction while the agent works |
| Bot events | `app_mention`, `message.im` | only mentions and DMs, never the rest of the channel's traffic |
| App Home → Messages tab | enabled, writable | lets people DM the bot |
| Socket Mode | off | Slack calls the public ingress over HTTPS (ADR 0004) |

The bot gets no `channels:history` scope, so it can't read the channel's other messages.

## 2. Install the app and copy its two credentials

1. **Settings → Install App → Install to Workspace → Allow.**
2. Copy the **Bot User OAuth Token** (`xoxb-…`) from the same page.
3. **Settings → Basic Information → App Credentials → Signing Secret → Show**, and copy it.

Put both in the lab's `.env`:

```bash
SLACK_SIGNING_SECRET=...
SLACK_BOT_TOKEN=xoxb-...
```

## 3. Store them in Secret Manager

```bash
task slack:secrets
```

This adds new versions of `bi-slack-signing-secret` (read only by the ingress service account) and
`bi-slack-bot-token` (read only by the worker service account). Terraform never sees the values.

The bridge reads secrets at runtime and caches a value for 10 minutes. A secret that had no value before is
picked up on the next request. If you **replace** a value (new app, rotated token), allow up to 10 minutes,
or force new instances with `task deploy:bridge`.

## 4. Verify the events Request URL

1. In the app's settings: **Features → Event Subscriptions**.
2. **Enable Events** should already be on, with the Request URL from the manifest. Click **Retry** next to it.
   It should turn into **Verified ✓**.
3. Check **Subscribe to bot events** lists `app_mention` and `message.im`, then **Save Changes**.

If the URL won't verify, the ingress is almost always rejecting the signature (see Troubleshooting).

## 5. Create a channel and add the bot

1. In Slack, create a channel, e.g. `#business-insights` (public or private).
2. In the channel, type `/invite @business-insights` (or channel name → **Integrations → Add apps**).
3. Optional: restrict the bot to specific channels. Get the channel ID from the channel name → **About** →
   bottom of the dialog (`C0…`), then:

   ```bash
   # .env
   SLACK_ALLOWED_CHANNELS=C0123ABCDEF          # comma-separated; DMs are always allowed
   ```

   ```bash
   task slack:allowlist   # re-applies only the ingress service; the deployed image stays
   ```

   Messages from other channels are acknowledged and ignored. The ingress logs
   `ignoring message from a channel outside the allowlist`.

## 6. Try it

In the channel:

```
@business-insights what was our revenue last month?
```

You should see a ⏳ reaction within a second or two. That means the ingress verified the event, queued it,
and the worker started. The answer arrives **in a thread** after roughly 15–90 seconds; the agent reads the
glossary and runs a few queries. Then:

- Reply **in the thread** with a follow-up ("and the month before?"). The thread is one agent session, so
  it keeps context.
- Tell it a preference ("always give me numbers in thousands"), then ask something in a **new** thread.
  Memory Bank stores preferences per Slack user.
- **DM the bot** (App Home → Messages, or click the bot's name → Message). DMs don't need an @mention.

## Troubleshooting

`task slack:logs` shows the last 30 minutes of both services. Each worker line carries `channel`,
`thread_ts`, `agent_session_id` and `event_id`.

| Symptom | Likely cause | Fix |
|---|---|---|
| Request URL won't verify | The ingress has no or the wrong signing secret (log: `rejected request with an invalid Slack signature`), or the bridge image isn't deployed (`task slack:check`) | `task slack:secrets` with the current app's secret, wait up to 10 min if it replaced an old value, **Retry** |
| No ⏳ at all | Bot not in the channel; channel not in `SLACK_ALLOWED_CHANNELS`; events not saved; message didn't @mention the bot | `/invite @business-insights`; check the allowlist log line; **Save Changes** in Event Subscriptions |
| ⏳ appears, no answer for minutes | Worker still waiting for the agent, or the agent has no revision yet | `task slack:logs`; `task traffic:status` (deploy with `task deploy:agent`) |
| "Sorry, I couldn't answer that this time. (ref `s-…`)" | The agent call failed; the ref is the session ID | find the `agent call failed` worker log with that `agent_session_id` |
| "I can't help with that request." | A guardrail (Model Armor) blocked the turn | expected for prompt-injection tests; see Model Armor logs |
| `not_in_channel` / `channel_not_found` in worker logs | The bot was removed from the channel | invite it again |
| `invalid_auth` / `token_revoked` in worker logs | Bot token changed (app reinstalled) | copy the new `xoxb-` token, `task slack:secrets`, wait up to 10 min or `task deploy:bridge` |
| Two answers to one question | A worker instance died mid-turn and Pub/Sub redelivered (rare). Slack's own retries are dropped at the ingress | nothing to do; see ADR 0004 |

## Removing it

`task down` deletes the bridge and the secrets. The Slack app itself lives in Slack: delete it under
**Basic Information → Delete App**, or keep it and point its Request URL at the new ingress after the next
`task up` + `task deploy`.
