#!/usr/bin/env bash
# Re-dispatch verifies that were escalated for a red that was never theirs, once
# `main` has moved past it.
#
# When a verify fails only on errors already present on `origin/main` (the
# task's diff did not cause them, so §Procedure step 4 forbids fixing them), the
# Architect records `<task>.base-red` holding the `origin/main` sha it built
# against and escalates. The task goes `blocked` and drops out of the pipeline.
# Nothing ever woke it again: when another task fixed `main`, the blocked verify
# still held a red sentinel describing a tree that no longer existed, and an
# operator had to delete the sentinel and re-dispatch by hand. One main-repair
# task verified green, rebased for freshness onto a `main` that had just picked
# up an unrelated compile break, escalated, and then sat blocked for hours after
# that break was fixed — with four other verifies stranded the same way.
#
# This closes that loop mechanically. For every `<task>.base-red` whose recorded
# sha is no longer `origin/main`:
#   1. the stale result is deleted FIRST — `.exit`, `.cloud.verdict`,
#      `.cloud.head`, the `.base-red` marker and the Verify-subtask alias
#      sentinel — so the next reader cannot act on it;
#   2. the escalated task, if still `blocked`, is put back to `todo` and its
#      assignee toggled through null, which is what fires `wakeOnDemand`.
# The relaunch that follows rebases onto current `origin/main` (§Detached
# launch), so a break that is really gone stays gone, and one that is still
# there re-escalates with a fresh marker.
#
# A marker whose sha IS current `origin/main` is left alone: nothing has changed
# on `main`, so re-running would only reproduce the same red.
#
# Marker format: line 1 the `origin/main` sha; line 2, optional, the identifier
# of the task that escalated (the `Verify:` subtask), defaulting to <task>.
#
# Usage: requeue-base-red.sh            # sweep, act
#        requeue-base-red.sh --dry-run  # sweep, report only
# Env:   PAPERCLIP_PROJECT (repo whose origin/main is compared; required),
#        PAPERCLIP_API_URL (default http://localhost:3100), PAPERCLIP_COMPANY_ID,
#        PAPERCLIP_API_KEY (optional bearer).
# Exit:  0 swept (including nothing to do), 2 origin/main unreadable.
set -uo pipefail

S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
API="${PAPERCLIP_API_URL:-http://localhost:3100}/api"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

: "${PAPERCLIP_PROJECT:?PAPERCLIP_PROJECT must name the project checkout}"
: "${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID must be set}"

git -C "$PAPERCLIP_PROJECT" fetch -q origin main 2>/dev/null
MAIN="$(git -C "$PAPERCLIP_PROJECT" rev-parse -q --verify origin/main)" \
  || { echo "requeue-base-red: cannot read origin/main in $PAPERCLIP_PROJECT" >&2; exit 2; }

api() { # method path [json]
  local auth=()
  [ -n "${PAPERCLIP_API_KEY:-}" ] && auth=(-H "Authorization: Bearer $PAPERCLIP_API_KEY")
  # No X-Paperclip-Run-Id: it binds to a run UUID, and a bad one half-applies a write.
  if [ $# -ge 3 ]; then
    curl -fsS --max-time 10 -X "$1" "${auth[@]}" -H 'Content-Type: application/json' -d "$3" "$API$2"
  else
    curl -fsS --max-time 10 -X "$1" "${auth[@]}" "$API$2"
  fi
}

# Prints "<uuid> <status> <assigneeAgentId|->" for an exact identifier match.
lookup() {
  api GET "/companies/$PAPERCLIP_COMPANY_ID/issues?q=$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d if isinstance(d, list) else d.get("issues", [])
for i in d:
    if i.get("identifier") == sys.argv[1]:
        print(i["id"], i.get("status"), i.get("assigneeAgentId") or "-")
        break' "$1"
}

shopt -s nullglob
for marker in "$S"/*.base-red; do
  task="$(basename "$marker" .base-red)"
  sha="$(sed -n 1p "$marker")"
  esc="$(sed -n 2p "$marker")"; esc="${esc:-$task}"
  if [ "$sha" = "$MAIN" ]; then
    echo "$task: main unchanged since the base-red ($sha) — left blocked"
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "$task: would requeue $esc (base-red $sha, main now $MAIN)"; continue
  fi

  # Clear before re-dispatch: a woken Architect must find no result, so it
  # launches rather than re-reading the stale red and escalating again.
  rm -f "$S/$task.exit" "$S/$task.cloud.verdict" "$S/$task.cloud.head" "$marker"
  [ "$esc" != "$task" ] && rm -f "$S/$esc.exit"

  id=""; status=""; assignee=""   # a failed read must not reuse the last marker's task
  read -r id status assignee < <(lookup "$esc" 2>/dev/null) || true
  if [ -z "$id" ]; then
    echo "$task: cleared; $esc not found in the task list — not re-dispatched"; continue
  fi
  if [ "$status" != "blocked" ]; then
    echo "$task: cleared; $esc is $status, not blocked — not re-dispatched"; continue
  fi
  if [ "$assignee" = "-" ]; then
    echo "$task: cleared; $esc has no assignee — not re-dispatched"; continue
  fi
  # wakeOnDemand fires on an assignee CHANGE, so rewriting the same value does
  # nothing: go through null and back. The field is assigneeAgentId — the
  # similar-looking assigneeId is accepted and silently dropped.
  # The comment says what resolved the block, as the Coordinator's unblock rule
  # requires of any cleared `blocked`. It goes in its own POST: a comment field
  # beside a status PATCH fails the whole write.
  if api PATCH "/issues/$id" '{"status":"todo","assigneeAgentId":null}' >/dev/null \
     && api PATCH "/issues/$id" "{\"assigneeAgentId\":\"$assignee\"}" >/dev/null; then
    api POST "/issues/$id/comments" "{\"body\":\"Requeued by requeue-base-red.sh: this was blocked on breakage already on main (origin/main $sha). origin/main is now $MAIN, so the stale result was deleted and the verify re-dispatched; the relaunch rebases onto it.\"}" >/dev/null || true
    echo "$task: requeued $esc (base-red $sha, main now $MAIN)"
  else
    echo "$task: cleared; re-dispatch of $esc FAILED — re-check its status and assignee"
  fi
done
exit 0
