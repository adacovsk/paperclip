#!/usr/bin/env bash
# The operator's merge of a `task/<id>` PR: merge the head only when the
# pipeline built it, and otherwise send it to be built instead of merging.
#
# WHY. The operator's merge is the final gate, and `gh pr merge` asks nothing.
# A PR that conflicts with `main` invited a hand resolution on the operator's
# machine, where cargo does not run, and the resolved head merged as if the
# verify behind the old head still spoke for it. One such merge dropped a
# closing brace from a test file: `main` stopped parsing, and every verify
# that synced onto it went red on a break none of them had made. The record
# that a head was built already exists (`pipeline/verify`, keyed on the SHA,
# see post-verify-status.sh) and branch protection would enforce it, but the
# project's plan does not offer branch protection on a private repository. So
# the check lives here, and the rule is that a `task/*` PR merges through this
# script and never through a bare `gh pr merge`.
#
# What it does with a head that is not green is the same thing the Dispatcher
# does, through the same scripts, so there is one way a build is launched:
#   a green sentinel not yet landed  -> land.sh (sync, freshness, gate, push, status)
#   no result and no build out       -> relaunch-verify.sh launch: the cloud lane
#                                       first, in resolve mode when the branch
#                                       conflicts, and this machine only when the
#                                       lane refuses the build
# It never resolves a conflict and never runs cargo itself.
#
# Usage:  op-merge.sh <pr>...        each PR in the order given
# Exit:   0  every PR named was merged
#         3  nothing is wrong, but at least one PR is not merged yet: its build
#            is out (or was just launched). Run again when it reports.
#         1  a PR needs someone to look; the line says why. Later PRs are still tried.
#         2  usage
# Env:    PAPERCLIP_PROJECT (required), XDG_CACHE_HOME,
#         ARCHITECT_CLOUD_LANE (default 1 here: the operator asked for a build;
#         cloud-pace.py still closes the lane on usage; 0 builds locally),
#         OP_MERGE_GH / OP_MERGE_LAND / OP_MERGE_RELAUNCH / OP_MERGE_CENSUS (test seams).
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: ${0##*/} <pr>..." >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
GH="${OP_MERGE_GH:-gh}"
LAND="${OP_MERGE_LAND:-$HERE/land.sh}"
RELAUNCH="${OP_MERGE_RELAUNCH:-$HERE/relaunch-verify.sh}"
CENSUS="${OP_MERGE_CENSUS:-$HERE/verify-census.sh}"
PROJECT="${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
export ARCHITECT_CLOUD_LANE="${ARCHITECT_CLOUD_LANE:-1}"
CONTEXT=pipeline/verify

cd "$PROJECT" || { echo "op-merge: no project at $PROJECT" >&2; exit 2; }
# Spelled out for every `gh` call: a bare `gh` in a fork acts on the parent.
REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@|https://)github\.com[:/]##; s#\.git$##')"
[ -n "$REPO" ] || { echo "op-merge: cannot read the project's origin" >&2; exit 2; }

# state, head branch, head sha, mergeable, draft flag and title of a PR, tab-separated.
pr_fields() {
  "$GH" pr view "$1" --repo "$REPO" --json state,headRefName,headRefOid,mergeable,isDraft,title \
    --jq '[.state, .headRefName, .headRefOid, .mergeable, .isDraft, .title] | @tsv'
}

# The newest pipeline/verify state on a SHA, or nothing.
verify_state() {
  "$GH" api "repos/$REPO/commits/$1/status" \
    --jq "[.statuses[] | select(.context == \"$CONTEXT\")][0].state // empty" 2>/dev/null
}

# A cloud watcher or a local chain still building this task.
build_out() {
  local pid
  pid="$(cat "$S/$1.pid" 2>/dev/null)"
  # The pid file outlives its watcher; a missing /proc entry is the ordinary case.
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q cloud-verify; then return 0; fi
  "$CENSUS" "$1" >/dev/null 2>&1
}

# 0 merged, 3 not yet, 1 someone has to look. `$2` stops a second landing.
one() {
  local pr="$1" landed="${2:-}" state branch sha mergeable draft title task wt sentinel out rc foreign
  IFS=$'\t' read -r state branch sha mergeable draft title < <(pr_fields "$pr")
  say() { echo "op-merge #$pr: $*"; }
  [ "${state:-}" = OPEN ] || { say "is ${state:-unreadable}, not OPEN"; return 1; }
  case "$branch" in
    task/*) task="${branch#task/}" ;;
    *) say "head $branch is not a task branch; this gate covers task/* only"; return 1 ;;
  esac

  if [ "$(verify_state "$sha")" = success ]; then
    # A draft is marked ready by land.sh, after the landing gate and with the
    # real body; GitHub refuses to merge one. Green and still a draft means that
    # step failed after the status was posted, so say which step rather than
    # report a refused merge.
    if [ "$draft" = true ]; then
      say "$CONTEXT is green on ${sha:0:9} but the PR is still a draft: land.sh did not mark it ready (read its output)"
      return 1
    fi
    # GitHub computes mergeability lazily; UNKNOWN right after a push is not a conflict.
    case "$mergeable" in
      MERGEABLE)
        "$GH" pr merge "$pr" --repo "$REPO" --merge --match-head-commit "$sha" >/dev/null \
          || { say "$CONTEXT is green on ${sha:0:9} but the merge was refused"; return 1; }
        say "merged ${sha:0:9}"; return 0 ;;
      UNKNOWN) say "$CONTEXT is green on ${sha:0:9}; GitHub has not computed mergeability yet"; return 3 ;;
    esac
    # Green, but main moved against it since: falls through to a fresh build.
  fi
  [ -z "$landed" ] || { say "landed, but ${sha:0:9} still has no green $CONTEXT"; return 1; }

  wt="$PROJECT/.paperclip/worktrees/$task"
  [ -d "$wt" ] || { say "no worktree for $task, so nothing here can build it"; return 1; }
  if build_out "$task"; then say "a verify of $task is out"; return 3; fi

  sentinel="$(cat "$S/$task.exit" 2>/dev/null)"
  if [ "$sentinel" = 0 ]; then
    out="$("$LAND" "$task" "$task" "$title" 2>&1)"; rc=$?
    case "$rc" in
      0) one "$pr" landed; return ;;
      2) say "${out##*$'\n'}"; return 3 ;;
      *) say "${out##*$'\n'}"; return 1 ;;
    esac
  fi
  [ -z "$sentinel" ] || { say "the last verify of $task ended $sentinel; read $S/$task.log before building again"; return 1; }

  # The lane publishes the worktree's head over the PR's. A commit only the PR
  # carries (pushed from somewhere else) would be discarded by that push.
  git -C "$wt" fetch -q origin main "$branch" 2>/dev/null || { say "cannot fetch origin"; return 1; }
  foreign="$(git -C "$wt" log --no-merges --format=%h "origin/$branch" --not HEAD origin/main | tr '\n' ' ')"
  [ -z "$foreign" ] || { say "the PR head carries commits the worktree lacks ($foreign); bring them into $wt first"; return 1; }

  # Whatever resolve ran before belonged to the head already in the PR.
  rm -f "$S/$task.cloud.resolve"
  out="$("$RELAUNCH" "$task" "$task" launch 2>&1)"; rc=$?
  say "${out##*$'\n'}"
  [ "$rc" = 0 ] && return 3
  return 1
}

worst=0
for pr in "$@"; do
  one "$pr"; rc=$?
  # 1 outranks 3 outranks 0.
  case "$rc" in
    1) worst=1 ;;
    3) [ "$worst" = 1 ] || worst=3 ;;
  esac
done
exit "$worst"
