#!/usr/bin/env bash
# Publish a task branch and open its draft PR as soon as the Worker's stage ends.
#
# WHY. The draft used to open only when a cloud verify launched, so the whole
# Review stage, and every local build, ran with nothing on GitHub to read. The
# Worker cannot push (no network), and before its first commit the branch has no
# diff a PR could show, so the end of the Worker's stage is the earliest a draft
# can exist. The Dispatcher runs this there, and again when it files the Verify,
# so the draft follows the Reviewer's commits too.
#
# It publishes only work nobody has landed. A ready PR's head is a landing: the
# Verify's close, `until_pr` holds and op-merge.sh all read it, and moving it
# would un-land the work. A closed or merged PR is the operator's decision. So
# with any PR other than an open draft, nothing is pushed.
#
# --no-verify: this push is a preview, not a landing. The pre-push hook runs the
# full guard suite, minutes under build load; land.sh's push, which makes the PR
# ready, still goes through it.
#
# Best effort, like open-draft.sh: every outcome exits 0 with a line saying why.
# A draft that does not open costs early visibility only; land.sh opens the PR.
#
# Usage:  publish-draft.sh <task-id>
# Env:    PAPERCLIP_PROJECT (required), PAPERCLIP_GH_USER;
#         PUBLISH_DRAFT_GH / PUBLISH_DRAFT_OPEN are test seams.
set -uo pipefail

task="${1:?task id}"
branch="task/$task"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}"
GH="${PUBLISH_DRAFT_GH:-gh}"
OPEN="${PUBLISH_DRAFT_OPEN:-$HERE/open-draft.sh}"
wt="$PROJECT/.paperclip/worktrees/$task"

say() { echo "publish-draft $task: $*"; exit 0; }
[ -d "$wt" ] || say "no worktree at $wt; nothing published"
cd "$wt" || say "cannot enter $wt"
[ "$(git branch --show-current)" = "$branch" ] || say "worktree is not on $branch; nothing published"

[ -n "${PAPERCLIP_GH_USER:-}" ] && { "$GH" auth switch --user "$PAPERCLIP_GH_USER" >/dev/null 2>&1 || true; }
others="$("$GH" pr list --head "$branch" --state all --json state,isDraft \
  -q '[.[] | select((.state == "OPEN" and .isDraft) | not)] | length')" || say "cannot list PRs for $branch"
[ "$others" = 0 ] || say "$branch already has a ready, closed or merged PR; left as it is"

git fetch -q origin main || say "cannot fetch origin/main"
[ -n "$(git rev-list -n1 origin/main..HEAD)" ] || say "no commits beyond main; nothing to show"

remote="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
head="$(git rev-parse HEAD)"
if [ "$remote" != "$head" ]; then
  if [ -n "$remote" ]; then
    # A commit only the remote carries (pushed from elsewhere) would be lost.
    # Compared by patch, so a Rebase stage's rewrite of the same commits is no loss.
    git fetch -q origin "$branch" || say "cannot fetch $branch"
    foreign="$(git rev-list --no-merges --right-only --cherry-pick --abbrev-commit HEAD...FETCH_HEAD --not origin/main | tr '\n' ' ')"
    [ -z "$foreign" ] || say "the remote $branch carries commits the worktree lacks ($foreign); not pushed"
  fi
  git push -q --no-verify --force-with-lease="$branch:$remote" origin "HEAD:$branch" \
    || say "push of $branch was rejected"
fi
"$OPEN" "$task"
