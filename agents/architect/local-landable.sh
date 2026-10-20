#!/usr/bin/env bash
# Whether a green LOCAL build can be landed by land.sh, without a model run.
#
# WHY. land.sh lands a green cloud verify with no model, but a local build went
# to the Architect every time, because a local build may carry the Architect's
# own fixes and the PR body has to list them for review. While the cloud lane
# is closed every build is local, so every landing cost a model run, even the
# common one where the Architect committed nothing. That case has nothing to
# list: the branch is exactly the Worker's and Reviewer's work, and the
# project's generator writes the body from the task and those commits.
#
# Narrow on purpose. Any commit not stamped `Stage: worker` or `Stage: reviewer`
# (an Architect fix, a schema regeneration, an unstamped hand commit) keeps
# today's path: the Architect lands it and writes the body. So does a head the
# build did not compile: the launch records the commit it built in
# `<task>.head`, and a build launched before that record existed has none.
#
# Usage:  local-landable.sh <task-id>
# Exit:   0  landable; 1 not, and the last line of output says why
# Env:    PAPERCLIP_PROJECT (required), XDG_CACHE_HOME
set -uo pipefail

task="${1:?task id}"
PROJECT="${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"

no() { echo "local-landable $task: $*"; exit 1; }

[ ! -e "$S/$task.cloud.verdict" ] || no "a cloud verify, not a local build"
[ "$(cat "$S/$task.exit" 2>/dev/null)" = "0" ] || no "the sentinel is not 0"
built="$(cat "$S/$task.head" 2>/dev/null)" || no "no recorded head for the build"
[ -s "$S/$task.base" ] || no "no recorded base for the build"
base="$(cat "$S/$task.base")"
cd "$PROJECT/.paperclip/worktrees/$task" 2>/dev/null || no "no worktree"
[ "$(git rev-parse HEAD)" = "$built" ] || no "the head moved after the build: ${built:0:9} was built"

# Merge commits are the launch's own sync onto main, not anyone's change.
stages="$(git log --no-merges --format='%H %(trailers:key=Stage,valueonly,separator=%x2C)' "$base..$built")" \
  || no "cannot read the commits since ${base:0:9}"
[ -n "$stages" ] || no "no commits since ${base:0:9}"
while read -r sha stage; do
  case "$stage" in
    worker|reviewer) ;;
    *) no "commit ${sha:0:9} is stamped '${stage:-nothing}', not worker or reviewer" ;;
  esac
done <<< "$stages"
echo "local-landable $task: yes"
