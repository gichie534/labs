#!/usr/bin/env bash
# Store the Slack app's signing secret and bot token (from .env / the shell) as new Secret Manager versions.
# The bridge reads them at runtime, so no redeploy is needed; new instances pick them up within 10 minutes.
set -euo pipefail
: "${GCP_PROJECT:?set GCP_PROJECT}"
: "${SLACK_SIGNING_SECRET:?set SLACK_SIGNING_SECRET (Slack app > Basic Information > Signing Secret)}"
: "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN (Slack app > OAuth & Permissions > Bot User OAuth Token, xoxb-...)}"

case "$SLACK_BOT_TOKEN" in
  xoxb-*) ;;
  *) echo "SLACK_BOT_TOKEN must be a bot token (xoxb-...)" >&2; exit 1 ;;
esac

printf '%s' "$SLACK_SIGNING_SECRET" | gcloud secrets versions add bi-slack-signing-secret --project="$GCP_PROJECT" --data-file=- >/dev/null
printf '%s' "$SLACK_BOT_TOKEN" | gcloud secrets versions add bi-slack-bot-token --project="$GCP_PROJECT" --data-file=- >/dev/null
echo "Stored new versions of bi-slack-signing-secret and bi-slack-bot-token."
