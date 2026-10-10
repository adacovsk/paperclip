#!/usr/bin/env bash
# Relaunch a verify in the cloud lane without a model run, for the two sentinel
# results whose next step is fixed by rule:
#
#   retry  `99` or `75`: the build never reported (wrapper signalled, worktree lock
#          never freed). The code was not judged, so the same head goes out again.
#   fresh  `0`, but origin/main moved past the verified base: §Landing's freshness
#          gate would re-verify. This runs that gate's re-verify branch and leaves
#          its landing branches (docs-only advance, cap reached) to Landing.
#
# WHY. The Dispatcher reads every sentinel, and these two outcomes used to wake
# the Architect only for it to run these same commands: a full context load per
# relaunch to reach a decision with no judgment in it. Anything this script is
# not sure of exits 1, and the caller wakes the Architect exactly as before, so
# the fallback is today's behaviour, never a dropped verify.
#
# Usage:  relaunch-verify.sh <task-id> <verify-task-id> retry|fresh
# Exit:   0  relaunched in the cloud lane; the next sentinel arrives as usual
#         3  fresh only: nothing to re-verify, Landing should run (main has not
#            moved in code, or the freshness cap is reached)
#         1  a model has to look: no worktree, wrong branch, dirty tree, a sync
#            conflict, or the lane refused the offload
# Env:    PAPERCLIP_PROJECT (required), XDG_CACHE_HOME, FRESHNESS_CAP (default 2,
#         as in §Landing), RELAUNCH_CV / RELAUNCH_FRESHNESS (test seams).
set -uo pipefail

task="${1:?task id}"; verify="${2:?verify task id}"; mode="${3:?retry|fresh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CV="${RELAUNCH_CV:-$HERE/cloud-verify.sh}"
FRESHNESS="${RELAUNCH_FRESHNESS:-$HERE/freshness-reverify-needed.sh}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
CAP="${FRESHNESS_CAP:-2}"

say() { echo "relaunch-verify $task: $*"; }

cd "${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}/.paperclip/worktrees/$task" 2>/dev/null \
  || { say "no worktree"; exit 1; }
[ "$(git branch --show-current)" = "task/$task" ] || { say "worktree is not on task/$task"; exit 1; }
# A dirty tree is an Architect's unfinished fix: offloading would publish the
# committed head without it, and the sync below would refuse anyway.
[ -z "$(git status --porcelain --untracked-files=no)" ] || { say "uncommitted changes in the worktree"; exit 1; }

offload() {
  rm -f "$S/$task.exit"
  if "$CV" offload "$task" "task/$task" "$verify" >/dev/null 2>&1; then
    say "relaunched in the cloud lane ($1)"; exit 0
  fi
  # The sentinel is already gone, so the woken Architect finds "absent + no
  # build" and launches the local chain: the same path a refused offload takes
  # inside its own run.
  say "the cloud lane refused the offload ($1)"; exit 1
}

case "$mode" in
  retry)
    offload "retry after an inconclusive build"
    ;;
  fresh)
    git fetch -q origin main || { say "cannot fetch origin/main"; exit 1; }
    main="$(git rev-parse origin/main)"
    old="$(cat "$S/$task.base" 2>/dev/null || true)"
    [ -n "$old" ] && [ "$old" != "$main" ] || { say "verified base is current; land"; exit 3; }
    # Landing re-checks both of these itself, after its own sync. Deciding them
    # before touching the branch keeps its past-the-cap flag intact: writing the
    # base here would make Landing see a fresh branch and land without saying so.
    "$FRESHNESS" "$old" "$main" || { say "origin/main moved only in documentation; land"; exit 3; }
    n="$(cat "$S/$task.freshness" 2>/dev/null || echo 0)"
    [ "$n" -lt "$CAP" ] || { say "freshness cap $CAP reached; land and flag"; exit 3; }
    # §Landing's sync, verbatim in effect: a branch already on origin is never
    # rebased, because Landing's push is not forced.
    { ! git ls-remote --exit-code --heads origin "task/$task" >/dev/null 2>&1 && git rebase -q origin/main 2>/dev/null; } \
      || { git rebase --abort >/dev/null 2>&1
           git merge -q --no-edit origin/main >/dev/null 2>&1 \
             || { git merge --abort >/dev/null 2>&1; say "neither rebase nor merge onto origin/main succeeds"; exit 1; }; }
    echo "$main" > "$S/$task.base"
    echo "$((n + 1))" > "$S/$task.freshness"
    offload "freshness re-verify $((n + 1))/$CAP"
    ;;
  *)
    say "unknown mode $mode"; exit 1
    ;;
esac
