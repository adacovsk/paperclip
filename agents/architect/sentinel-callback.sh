#!/usr/bin/env bash
# Announce that a verify sentinel is readable. Called by the local verify
# launch and by cloud-verify.sh's watcher when they write `<task>.exit`.
#
# The callback wakes the Dispatcher, not the Architect. Waking the Architect
# bought a full model run per sentinel, and most of those runs only found that
# nothing needed doing: a result already handled, a superseded verdict, or a red
# that is main's and already recorded. The Dispatcher's sentinel step reads the
# result for free and wakes the Architect only when a model has work to do.
# The wake carries no issue: a payload naming one would make the Dispatcher's
# run task-scoped and take that task's execution lock.
#
# Usage: sentinel-callback.sh <verify-task-id>
# Falls back to waking $PAPERCLIP_AGENT_ID on that task, the old callback, when
# the Dispatcher cannot be found — a late sentinel is worse than a wasted run.
set -uo pipefail
[ -n "${PAPERCLIP_API_URL:-}" ] || exit 0
issue="${1:-}"
auth=()
[ -n "${PAPERCLIP_API_KEY:-}" ] && auth=(-H "Authorization: Bearer $PAPERCLIP_API_KEY")

dispatcher="$(curl -fsS --max-time 10 "${auth[@]}" \
  "$PAPERCLIP_API_URL/api/companies/${PAPERCLIP_COMPANY_ID:-}/agents" 2>/dev/null \
  | python3 -c 'import json,sys
for a in json.load(sys.stdin):
    if a.get("name") == "Dispatcher":
        print(a["id"]); break' 2>/dev/null)"

if [ -n "$dispatcher" ]; then
  curl -fsS --max-time 10 -X POST "${auth[@]}" -H 'Content-Type: application/json' \
    "$PAPERCLIP_API_URL/api/agents/$dispatcher/wakeup" \
    -d '{"source":"automation","triggerDetail":"callback","reason":"verify-sentinel-ready"}' \
    >/dev/null 2>&1 && exit 0
fi
[ -n "${PAPERCLIP_AGENT_ID:-}" ] || exit 0
curl -fsS --max-time 10 -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID/wakeup" \
  -d "{\"source\":\"automation\",\"triggerDetail\":\"callback\",\"reason\":\"verify-sentinel-ready\",\"payload\":{\"issueIdentifier\":\"${issue}\"}}" \
  >/dev/null 2>&1 || true
