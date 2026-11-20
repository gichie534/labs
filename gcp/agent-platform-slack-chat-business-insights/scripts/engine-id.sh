#!/usr/bin/env bash
# Print the reasoning engine ID: AGENT_ENGINE_ID if set, else the agent-runtime/business-insights unit's Terraform output.
set -euo pipefail
if [ -n "${AGENT_ENGINE_ID:-}" ]; then
  echo "$AGENT_ENGINE_ID"
  exit 0
fi
cd "$(dirname "$0")/../infra/agent-runtime/business-insights"
id="$(terragrunt output -raw engine_id 2>/dev/null || true)"
if [ -z "$id" ]; then
  echo "No reasoning engine yet: run 'task up' first (or set AGENT_ENGINE_ID)." >&2
  exit 1
fi
echo "$id"
