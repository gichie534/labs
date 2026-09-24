#!/usr/bin/env bash
# ONE-OFF OPERATIONAL SCRIPT — NOT PART OF THE LAB LIFECYCLE.
#
# Migrates VictoriaLogs data between two REAL clusters over `kubectl port-forward`, for the case where
# there is no private network path between them. It reuses the lab's migrator binary; everything about the
# lab's own topology (the VPN, the Jobs, the seeded dataset) is bypassed.
#
# It is deliberately split into two subcommands so that nothing can write to the target by accident:
#
#   inspect   READ-ONLY. Lists the source's field names and values, and dry-runs your filter to show how
#             many lines it matches. Run this first, always.
#   migrate   Writes to the target. Only does anything once you have a filter that `inspect` says matches
#             the number of lines you expect.
#
# WHAT IT ASSUMES
#
# The SOURCE port-forward is YOUR responsibility, held open in another terminal. That is deliberate: it
# keeps this script working when the source cluster needs credentials this shell does not have (e.g. an
# EKS kubeconfig whose exec block shells out to `aws eks get-token`).
#
#   kubectl --context <source-ctx> -n <ns> port-forward svc/<vl-service> 19428:9428
#
# The TARGET port-forward is started and cleaned up by this script.
#
# THE IRREVERSIBLE PART
#
# VictoriaLogs has no deduplication and no delete-by-query. Anything imported cannot be removed short of
# recreating the target's storage. A re-run, or a retry after a dropped connection, duplicates whatever
# was already transferred. Nothing here can undo that, so `inspect` exists to make the decision with the
# numbers in front of you.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATOR_DIR="$LAB_DIR/deploy/migrator"

# --- Configuration (override via environment) -------------------------------------------------------
# The source forward YOU hold open.
SOURCE_VL_URL="${SOURCE_VL_URL:-http://localhost:19428}"

# The target, port-forwarded by this script.
TARGET_CONTEXT="${TARGET_CONTEXT:-gke_grace-prod-506909_europe-west9_grace-prod}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-vl}"
TARGET_SERVICE="${TARGET_SERVICE:-vl-vls-server}"
TARGET_PORT="${TARGET_PORT:-9428}"
TARGET_LOCAL_PORT="${TARGET_LOCAL_PORT:-29428}"
TARGET_VL_URL="http://localhost:${TARGET_LOCAL_PORT}"

# What to move, and over what range.
MIGRATE_QUERY="${MIGRATE_QUERY:-*}"
MIGRATE_START="${MIGRATE_START:-}"
MIGRATE_END="${MIGRATE_END:-}"

# Stamped onto every imported entry. An underscore rather than a hyphen: a hyphenated field name has to
# be quoted in every LogsQL query that touches it ("migrated-from":prod-eks), an underscore does not.
MIGRATE_EXTRA_FIELDS="${MIGRATE_EXTRA_FIELDS:-migrated_from=prod-eks}"

# Smaller windows mean more requests but a more resumable transfer. A port-forward is one TCP stream
# through the API server and drops under sustained load, so hours beat days here.
MIGRATE_STEP_HOURS="${MIGRATE_STEP_HOURS:-6}"
MIGRATE_WINDOW_RETRIES="${MIGRATE_WINDOW_RETRIES:-3}"
CHUNK_LINES="${CHUNK_LINES:-2000}"

# No guard: a re-run is expected to be possible here. Set MIGRATE_GUARD_QUERY to refuse when the target
# already holds matching lines.
MIGRATE_GUARD_QUERY="${MIGRATE_GUARD_QUERY:-}"

TARGET_PF_PID=""

cleanup() {
  if [ -n "$TARGET_PF_PID" ] && kill -0 "$TARGET_PF_PID" 2>/dev/null; then
    echo "==> stopping target port-forward (pid $TARGET_PF_PID)"
    kill "$TARGET_PF_PID" 2>/dev/null || true
    wait "$TARGET_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

die() { echo "ERROR: $*" >&2; exit 1; }

# wait_ready polls a VictoriaLogs instance until it answers. VictoriaLogs has no /-/ready, so a trivial
# query is used as the liveness signal.
wait_ready() {
  local url="$1" label="$2" i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 5 "$url/select/logsql/query?query=%2A%20%7C%20limit%201" >/dev/null 2>&1; then
      echo "    $label ready at $url"
      return 0
    fi
    sleep 1
  done
  return 1
}

check_source() {
  echo "==> checking the SOURCE forward you are holding open: $SOURCE_VL_URL"
  if ! wait_ready "$SOURCE_VL_URL" "source"; then
    die "the source is not answering at $SOURCE_VL_URL.
       Start it in another terminal and leave it running:
         kubectl --context <source-ctx> -n <ns> port-forward svc/<vl-service> 19428:9428
       If it IS running, check the local port matches SOURCE_VL_URL."
  fi
}

start_target_forward() {
  echo "==> starting the TARGET port-forward ($TARGET_CONTEXT $TARGET_NAMESPACE/$TARGET_SERVICE)"
  kubectl --context "$TARGET_CONTEXT" -n "$TARGET_NAMESPACE" \
    port-forward "svc/$TARGET_SERVICE" "${TARGET_LOCAL_PORT}:${TARGET_PORT}" >/dev/null 2>&1 &
  TARGET_PF_PID=$!
  if ! wait_ready "$TARGET_VL_URL" "target"; then
    die "the target did not become reachable on localhost:$TARGET_LOCAL_PORT.
       Check: kubectl --context $TARGET_CONTEXT -n $TARGET_NAMESPACE get svc $TARGET_SERVICE"
  fi
}

run_migrator() {
  ( cd "$MIGRATOR_DIR" && go run . "$@" )
}

cmd_inspect() {
  check_source
  echo ""
  echo "########## SOURCE (read-only) ##########"
  VL_URL="$SOURCE_VL_URL" \
  FIELDS_START="$MIGRATE_START" \
  FIELDS_END="$MIGRATE_END" \
  FIELDS_FIELD="${FIELDS_FIELD:-}" \
  FIELDS_QUERY="$MIGRATE_QUERY" \
    run_migrator fields

  echo "########## TARGET (read-only) ##########"
  start_target_forward
  VL_URL="$TARGET_VL_URL" \
  FIELDS_START="$MIGRATE_START" \
  FIELDS_END="$MIGRATE_END" \
  FIELDS_QUERY="${MIGRATE_EXTRA_FIELDS%%=*}:*" \
    run_migrator fields

  cat <<'EOF'
Next, if the numbers look right:

  1. Narrow MIGRATE_START/MIGRATE_END to ONE short window and migrate that first. A pilot costs a few
     thousand lines; a wrong filter across the whole range costs a cleanup you cannot perform.
  2. Check the pilot landed:  {"migrated_from":"prod-eks"} in the target, over the pilot window.
  3. Then widen the range.

  MIGRATE_START=... MIGRATE_END=... MIGRATE_QUERY='...' ./scripts/prod-migrate-logs.sh migrate
EOF
}

cmd_migrate() {
  [ -n "$MIGRATE_START" ] || die "MIGRATE_START is required for migrate (RFC3339, e.g. 2026-09-01T00:00:00Z)"
  [ -n "$MIGRATE_END" ] || die "MIGRATE_END is required for migrate (RFC3339)"

  check_source
  start_target_forward

  cat <<EOF

########## ABOUT TO WRITE TO THE TARGET ##########
  source : $SOURCE_VL_URL
  target : $TARGET_VL_URL  ($TARGET_CONTEXT $TARGET_NAMESPACE/$TARGET_SERVICE)
  filter : $MIGRATE_QUERY
  window : $MIGRATE_START .. $MIGRATE_END  (step ${MIGRATE_STEP_HOURS}h)
  tagging: $MIGRATE_EXTRA_FIELDS
  guard  : ${MIGRATE_GUARD_QUERY:-<none — a re-run will duplicate lines>}

  This cannot be undone: VictoriaLogs has no delete-by-query.
EOF
  printf '\nType the word migrate to proceed: '
  read -r confirm
  [ "$confirm" = "migrate" ] || die "aborted"
  echo ""

  SOURCE_VL_URL="$SOURCE_VL_URL" \
  TARGET_VL_URL="$TARGET_VL_URL" \
  MIGRATE_START="$MIGRATE_START" \
  MIGRATE_END="$MIGRATE_END" \
  MIGRATE_QUERY="$MIGRATE_QUERY" \
  MIGRATE_EXTRA_FIELDS="$MIGRATE_EXTRA_FIELDS" \
  MIGRATE_GUARD_QUERY="$MIGRATE_GUARD_QUERY" \
  MIGRATE_STEP_HOURS="$MIGRATE_STEP_HOURS" \
  MIGRATE_WINDOW_RETRIES="$MIGRATE_WINDOW_RETRIES" \
  CHUNK_LINES="$CHUNK_LINES" \
    run_migrator migrate-logs

  cat <<EOF

To check it landed, query the target for the provenance tag over the same window:
  {$(printf '%s' "${MIGRATE_EXTRA_FIELDS%%=*}"):"${MIGRATE_EXTRA_FIELDS#*=}"}
EOF
}

case "${1:-}" in
  inspect) cmd_inspect ;;
  migrate) cmd_migrate ;;
  *)
    cat <<EOF
Usage: $0 {inspect|migrate}

  inspect   read-only: field names, field values, and a dry run of your filter on BOTH sides
  migrate   writes to the target; requires MIGRATE_START and MIGRATE_END, and a typed confirmation

Environment (defaults in brackets):
  SOURCE_VL_URL          [$SOURCE_VL_URL]   the forward you hold open
  TARGET_CONTEXT         [$TARGET_CONTEXT]
  TARGET_NAMESPACE       [$TARGET_NAMESPACE]
  TARGET_SERVICE         [$TARGET_SERVICE]
  MIGRATE_QUERY          [$MIGRATE_QUERY]   LogsQL filter
  MIGRATE_START          [<unset>]          RFC3339, required for migrate
  MIGRATE_END            [<unset>]          RFC3339, required for migrate
  MIGRATE_EXTRA_FIELDS   [$MIGRATE_EXTRA_FIELDS]
  MIGRATE_STEP_HOURS     [$MIGRATE_STEP_HOURS]
  MIGRATE_WINDOW_RETRIES [$MIGRATE_WINDOW_RETRIES]
  FIELDS_FIELD           [<unset>]          inspect: list this field's values

Start the source forward first, in another terminal:
  kubectl --context <source-ctx> -n <ns> port-forward svc/<vl-service> 19428:9428
EOF
    exit 2
    ;;
esac
