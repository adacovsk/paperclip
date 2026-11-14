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
# MAIN MOVING IS NOT THE BREAK BEING FIXED. A marker that records its failing
# sites is requeued only once some commit in `<sha>..origin/main` plausibly
# touches the break: it changes a failing site's file, or it adds or removes a
# line naming an identifier the error quotes in backticks (a missing-field
# error is fixed in the struct, not at the initializer it was reported at).
# Requeueing on any sha change re-dispatched every base-red verify on every
# unrelated merge while the repair was still unlanded: one stretch spent about
# 116 Architect runs, four per stranded verify, each coming back on the same
# error. A marker with no recorded sites falls back to the sha test.
#
# ONE SWEEP AT A TIME. The Dispatcher and the Coordinator both run this, and two
# overlapping sweeps toggled the same verify twice, 3 s apart. A non-blocking
# `flock` makes a second sweep exit at once; the lock dies with its holder.
#
# A KILLED SWEEP MUST NOT STRAND A VERIFY. The caller runs this under a timeout
# that kills, not signals. A kill between the null PATCH and the re-assignment
# left a verify `todo` with no assignee, which nothing would ever wake (the
# next pass reads it as "not yet blocked"). So each re-dispatch first writes
# `<task>.requeue-pending` (issue id + assignee) and removes it only once the
# assignee is back; every sweep starts by finishing any toggle a pending record
# says was cut off.
#
# Marker format: line 1 the `origin/main` sha; line 2, optional, the identifier
# of the task that escalated (the `Verify:` subtask), defaulting to <task>;
# lines 3+, optional, one failing site each, `<path>:<line> [<code> <message>]`.
#
# Usage: requeue-base-red.sh            # sweep, act
#        requeue-base-red.sh --dry-run  # sweep, report only
# Env:   PAPERCLIP_PROJECT (repo whose origin/main is compared; required),
#        PAPERCLIP_API_URL (default http://localhost:3100),
#        PAPERCLIP_API_KEY (optional bearer).
# Exit:  0 swept (including nothing to do), 2 origin/main unreadable.
set -uo pipefail

S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
API="${PAPERCLIP_API_URL:-http://localhost:3100}/api"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

: "${PAPERCLIP_PROJECT:?PAPERCLIP_PROJECT must name the project checkout}"

mkdir -p "$S"
exec 9>"$S/.requeue-base-red.lock"
flock -n 9 || { echo "requeue-base-red: another sweep holds the lock — skipped"; exit 0; }

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
  api GET "/issues?q=$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d if isinstance(d, list) else d.get("issues", [])
for i in d:
    if i.get("identifier") == sys.argv[1]:
        print(i["id"], i.get("status"), i.get("assigneeAgentId") or "-")
        break' "$1"
}

# Prints "<uuid> blocked <assigneeAgentId|-> <identifier>" for the newest
# blocked issue titled `Verify: <task>` (and not `Verify: <task>0…`).
lookup_verify() {
  api GET "/issues?q=$1" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
d = d if isinstance(d, list) else d.get("issues", [])
pat = re.compile(r"Verify: " + re.escape(sys.argv[1]) + r"(?![0-9A-Za-z])")
hits = [i for i in d if i.get("status") == "blocked" and pat.match(i.get("title") or "")]
hits.sort(key=lambda i: i.get("issueNumber") or 0, reverse=True)
if hits:
    i = hits[0]
    print(i["id"], "blocked", i.get("assigneeAgentId") or "-", i.get("identifier"))' "$1"
}

# Prints a reason when `<sha>..origin/main` plausibly touches the recorded
# break, nothing otherwise. Exit 2 when the marker records no sites.
break_touched() { # marker task sha
  local sites paths idents p hit
  sites="$(sed -n '3,$p' "$1")"
  [ -n "$sites" ] || return 2
  # A site is `<path>:<line> ...` for a compile error and `<path>:<key> ...` for a
  # data guard (`level_01.spells.json:runic_body`). Matching only a numeric suffix
  # dropped every data-file site, and a fix to the named file never requeued its
  # verifies: they sat blocked hours after main went green. A path has a `/` or `.`.
  paths="$(printf '%s\n' "$sites" | sed -n 's/^\([^ :]*[./][^ :]*\):[^ ]*.*/\1/p' | sort -u)"
  idents="$( { printf '%s\n' "$sites"
               sed -n '/^--- errors ---/,$p' "$S/$2.cloud.verdict" 2>/dev/null
             } | grep -o '`[A-Za-z_][A-Za-z0-9_]*`' | tr -d '`' | sort -u)"
  if [ -n "$paths" ]; then
    # shellcheck disable=SC2086 # one pathspec per site
    hit="$(git -C "$PAPERCLIP_PROJECT" log --format=%h "$3..$MAIN" -- $paths 2>/dev/null | head -1)"
    [ -n "$hit" ] && { echo "$hit touches $(printf '%s' "$paths" | tr '\n' ' ')"; return 0; }
  fi
  for p in $idents; do
    hit="$(git -C "$PAPERCLIP_PROJECT" log --format=%h -G "\\b$p\\b" "$3..$MAIN" -- '*.rs' 2>/dev/null | head -1)"
    [ -n "$hit" ] && { echo "$hit changes a line naming \`$p\`"; return 0; }
  done
  return 1
}

shopt -s nullglob
# Finish any re-dispatch a killed sweep left between the null PATCH and the
# re-assignment. A verify someone has since re-assigned is left as it is.
for pending in "$S"/*.requeue-pending; do
  task="$(basename "$pending" .requeue-pending)"
  read -r pid passignee pesc < "$pending" || true
  [ -n "${pid:-}" ] && [ -n "${passignee:-}" ] || { rm -f "$pending"; continue; }
  if [ "$DRY" = 1 ]; then echo "$task: would finish the cut-off re-dispatch of ${pesc:-$task}"; continue; fi
  cur="$(api GET "/issues/$pid" 2>/dev/null | python3 -c '
import json, sys
i = json.load(sys.stdin)
print(i.get("assigneeAgentId") or "-")' 2>/dev/null)" || cur=""
  case "$cur" in
    "") echo "$task: cannot read ${pesc:-$task} — pending re-dispatch kept for the next pass"; continue ;;
    -)  if api PATCH "/issues/$pid" "{\"assigneeAgentId\":\"$passignee\"}" >/dev/null; then
          rm -f "$S/$task.base-red" "$pending"
          echo "$task: finished the cut-off re-dispatch of ${pesc:-$task}"
        else
          echo "$task: finishing the re-dispatch of ${pesc:-$task} FAILED — kept for the next pass"
        fi ;;
    *)  rm -f "$S/$task.base-red" "$pending"
        echo "$task: ${pesc:-$task} was re-assigned since the cut-off sweep — pending record cleared" ;;
  esac
done

for marker in "$S"/*.base-red; do
  task="$(basename "$marker" .base-red)"
  sha="$(sed -n 1p "$marker")"
  esc="$(sed -n 2p "$marker")"; esc="${esc:-$task}"
  if [ "$sha" = "$MAIN" ]; then
    echo "$task: main unchanged since the base-red ($sha) — left blocked"
    continue
  fi
  [ -e "$S/$task.requeue-pending" ] && continue   # still unfinished above; retried next pass
  touched="$(break_touched "$marker" "$task" "$sha")"; rc=$?
  if [ "$rc" = 1 ]; then
    echo "$task: nothing in ${sha:0:9}..${MAIN:0:9} touches the recorded break — left blocked"
    continue
  fi
  why="${touched:-origin/main moved and the marker records no failing site}"
  if [ "$DRY" = 1 ]; then
    echo "$task: would requeue $esc (base-red $sha, main now $MAIN; $why)"; continue
  fi

  id=""; status=""; assignee=""; pred=""   # a failed read must not reuse the last marker's task
  read -r id status assignee < <(lookup "$esc" 2>/dev/null) || true
  # The named task is whoever escalated first. A later `Verify:` subtask can
  # re-escalate the same red and keep the marker, so the name may be a
  # cancelled or done predecessor while the live verify sits blocked. Clearing
  # the marker on the stale name would then strand that verify with nothing
  # left to wake it, so fall back to the newest blocked `Verify: <task>`.
  if [ "$status" != "blocked" ]; then
    fb=""; fbid=""; fbst=""; fbas=""
    read -r fbid fbst fbas fb < <(lookup_verify "$task" 2>/dev/null) || true
    if [ -n "$fbid" ]; then
      [ "$fb" != "$esc" ] && pred="$esc"
      id="$fbid"; status="$fbst"; assignee="$fbas"; esc="$fb"
    fi
  fi
  # Nothing is deleted until a blocked verify is in hand. The Architect writes
  # the marker and only then PATCHes its verify `blocked`; a pass landing
  # between the two sees a live verify, and clearing the marker there leaves
  # the block it is about to write with nothing that can ever release it.
  case "$status" in
    done|cancelled)
      rm -f "$S/$task.exit" "$S/$task.cloud.verdict" "$S/$task.cloud.head" "$S/$task.cloud.launched" "$marker"
      echo "$task: cleared; $esc is $status — not re-dispatched"; continue ;;
    blocked) ;;
    "")
      # A failed read and an unknown name look the same here, and an API
      # outage must not wipe every marker on the box.
      echo "$task: $esc not found in the task list — marker kept"; continue ;;
    *)
      echo "$task: $esc is $status, not yet blocked — marker kept for a later pass"; continue ;;
  esac
  if [ "$assignee" = "-" ]; then
    echo "$task: $esc has no assignee — marker kept, not re-dispatched"; continue
  fi

  # Clear before re-dispatch: a woken Architect must find no result, so it
  # launches rather than re-reading the stale red and escalating again. The
  # cloud launch record goes too: with it and no sentinel the state reads as a
  # dead watcher, and resuming that waits on a verdict that was already read.
  rm -f "$S/$task.exit" "$S/$task.cloud.verdict" "$S/$task.cloud.head" "$S/$task.cloud.launched"
  [ "$esc" != "$task" ] && rm -f "$S/$esc.exit"
  [ -n "$pred" ] && rm -f "$S/$pred.exit"
  # wakeOnDemand fires on an assignee CHANGE, so rewriting the same value does
  # nothing: go through null and back. The field is assigneeAgentId — the
  # similar-looking assigneeId is accepted and silently dropped.
  # The comment says what resolved the block, as the Coordinator's unblock rule
  # requires of any cleared `blocked`. It goes in its own POST: a comment field
  # beside a status PATCH fails the whole write.
  # The comment goes in while the task is unassigned: posted after the
  # reassignment it wakes the assignee a second time, and that run only reads
  # the comment and exits (half of all requeue-driven Architect runs were that).
  printf '%s %s %s\n' "$id" "$assignee" "$esc" > "$S/$task.requeue-pending"
  if ! api PATCH "/issues/$id" '{"status":"todo","assigneeAgentId":null}' >/dev/null; then
    rm -f "$S/$task.requeue-pending"   # nothing was toggled, so nothing to finish
    echo "$task: re-dispatch of $esc FAILED — marker kept; the next pass retries"
    continue
  fi
  api POST "/issues/$id/comments" "{\"body\":\"Requeued by requeue-base-red.sh: this was blocked on breakage already on main (origin/main $sha). origin/main is now $MAIN ($why), so the stale result was deleted and the verify re-dispatched; the relaunch rebases onto it.\"}" >/dev/null || true
  if api PATCH "/issues/$id" "{\"assigneeAgentId\":\"$assignee\"}" >/dev/null; then
    # The marker goes last: until the wake has fired it is the only record
    # that this block is waiting on main.
    rm -f "$marker" "$S/$task.requeue-pending"
    echo "$task: requeued $esc (base-red $sha, main now $MAIN; $why)"
  else
    echo "$task: re-assigning $esc FAILED — the pending record makes the next pass finish it"
  fi
done
exit 0
