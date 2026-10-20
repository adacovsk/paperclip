#!/usr/bin/env bash
# §Landing for an accepted green cloud verify, or a local green the Architect
# added nothing to, without a model run.
#
# WHY. A green sentinel woke the Architect, which loaded its whole instruction
# set to type out the §Landing block: sync onto main, run the freshness gate,
# run the landing gate, push, open the PR. None of those steps is a judgement
# once the cloud lane has accepted the build: the verdict already holds the
# schema result and every out-of-scope fix, and the PR body's reasons are
# copied from the task and the commits by the project's generator. Landing was
# the most frequent Architect run and the one with nothing for a model to do.
#
# What still needs a model exits 1 and the caller wakes the Architect exactly
# as before, so a refusal here costs today's behaviour, never a dropped verify:
# a local build that local-landable.sh refuses (it may carry the Architect's
# own fixes, which its PR body has to list), a dirty tree, a red landing gate, a conflict a resolve
# verify already failed on, or a PR already closed or merged for the branch.
#
# Usage:  land.sh <task-id> <verify-task-id> <task-title>
# Exit:   0  landed: the branch is pushed and a PR for it exists
#         2  not landed, a new build is out: a freshness re-verify, or a
#            resolve-mode verify of a branch that conflicts with main
#         1  a model has to look; the last line of output says why
# Env:    PAPERCLIP_PROJECT, PAPERCLIP_GH_USER (required), XDG_CACHE_HOME,
#         LAND_RELAUNCH / LAND_FRESHNESS / LAND_CV / LAND_STATUS / LAND_GH /
#         LAND_GATE / LAND_BODY / LAND_BODY_CHECK / LAND_LOCAL (test seams; LAND_GATE stands in
#         for the explicit gate only, never for the pre-push hook).
set -uo pipefail

task="${1:?task id}"; verify="${2:?verify task id}"; title="${3:?task title}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAUNCH="${LAND_RELAUNCH:-$HERE/relaunch-verify.sh}"
FRESHNESS="${LAND_FRESHNESS:-$HERE/freshness-reverify-needed.sh}"
CV="${LAND_CV:-$HERE/cloud-verify.sh}"
STATUS="${LAND_STATUS:-$HERE/post-verify-status.sh}"
LOCAL="${LAND_LOCAL:-$HERE/local-landable.sh}"
GH="${LAND_GH:-gh}"
PROJECT="${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
branch="task/$task"

say() { echo "land $task: $*"; }
model() { say "$*"; exit 1; }

gate() {
  if [ -n "${LAND_GATE:-}" ]; then "$LAND_GATE" "$1"; return; fi
  ( cd "$PROJECT" && pixi run -e dev verify --head "$1" )
}
body() {
  if [ -n "${LAND_BODY:-}" ]; then "$LAND_BODY" "$task"; return; fi
  ( cd "$PROJECT" && pixi run -e dev python scripts/generate_pr_body.py "$task" )
}
body_check() {
  if [ -n "${LAND_BODY_CHECK:-}" ]; then "$LAND_BODY_CHECK" "$1"; return; fi
  ( cd "$PROJECT" && pixi run -e dev python scripts/check_pr_body.py \
      --head-ref "$branch" --title "$title" --body-file "$1" )
}

WORKTREE="$PROJECT/.paperclip/worktrees/$task"
cd "$WORKTREE" 2>/dev/null || model "no worktree"
[ "$(git branch --show-current)" = "$branch" ] || model "worktree is not on $branch"
[ "$(cat "$S/$task.exit" 2>/dev/null)" = "0" ] || model "the sentinel is not 0"
[ -z "$(git status --porcelain --untracked-files=no)" ] || model "uncommitted changes in the worktree"
[ -s "$S/$task.base" ] || model "no recorded base for the green build"
if [ -f "$S/$task.cloud.verdict" ]; then
  verdict="$(cat "$S/$task.cloud.verdict")"
  [ "$(sed -n 's/^result: *//p' <<< "$verdict" | head -1)" = "PASS" ] || model "the cloud verdict is not PASS"
else
  verdict=""
  why="$("$LOCAL" "$task" 2>&1)" || model "local build: ${why##*$'\n'}"
fi

"$GH" auth switch --user "${PAPERCLIP_GH_USER:?set PAPERCLIP_GH_USER}" >/dev/null 2>&1 || true

# A closed PR is a decision and a merged one is landed; either is the
# Coordinator's to record. Pushing onto that branch would publish to nothing.
prs="$("$GH" pr list --head "$branch" --state all --json number,state -q '.[] | "\(.number) \(.state)"')" \
  || model "cannot list PRs for $branch"
if grep -qvE ' OPEN$' <<< "${prs:-x OPEN}"; then
  model "a PR for $branch is already closed or merged ($(tr '\n' ' ' <<< "$prs"))"
fi

# Freshness: relaunch-verify.sh owns the re-verify decision so the two cannot
# disagree. 0 = a re-verify is out; 3 = land; 1 = it could not proceed, which
# for a conflict is a resolve verify and anything else is a model's.
out="$("$RELAUNCH" "$task" "$verify" fresh 2>&1)"; rc=$?
case "$rc" in
  0) say "${out##*$'\n'}"; exit 2 ;;
  3) ;;
  *) case "$out" in
       *"neither rebase nor merge"*) ;;
       *) model "relaunch-verify.sh: ${out##*$'\n'}" ;;
     esac ;;
esac

resolve() {
  # Step 0's conflict rule: offload the un-rebased head in resolve mode, once.
  [ ! -e "$S/$task.cloud.resolve" ] || model "conflicts with origin/main and a resolve verify was already tried"
  rm -f "$S/$task.exit"
  if CLOUD_VERIFY_RESOLVE=1 "$CV" offload "$task" "$branch" "$verify" >/dev/null 2>&1; then
    say "conflicts with origin/main; sent to the cloud lane in resolve mode"; exit 2
  fi
  echo 0 > "$S/$task.exit"
  model "conflicts with origin/main and the cloud lane refused the resolve offload"
}
[ "$rc" = "3" ] || resolve

# §Landing's sync. A branch already on origin is never rebased: the push below
# is not forced, and a rewritten tip would be rejected.
git fetch -q origin main || model "cannot fetch origin/main"
note=""
old="$(cat "$S/$task.base")"
main="$(git rev-parse origin/main)"
if [ "$old" != "$main" ]; then
  { ! git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 && git rebase -q origin/main 2>/dev/null; } \
    || { git rebase --abort >/dev/null 2>&1
         git merge -q --no-edit origin/main >/dev/null 2>&1 \
           || { git merge --abort >/dev/null 2>&1; resolve; }; }
  echo "$main" > "$S/$task.base"
  # relaunch-verify.sh said land, so main's advance either cannot reach this branch
  # or past the freshness cap. Say which: the cap lands an unbuilt advance.
  if "$FRESHNESS" "$old" "$main"; then
    note="cargo green on an older main; rebased onto main unbuilt (freshness cap)"
    say "FRESHNESS CAP HIT: landing on ${main:0:9} without re-verifying the latest advance"
  else
    note="cargo green; main advanced since, sharing no file, data directory, data reader or symbol with this branch"
  fi
fi

# The landing gate runs once. The project's pre-push hook is the same
# `verify --head <sha>`, so where it is installed and this head is new to origin
# the push is the gate; running both doubled the slowest step of a landing.
# Otherwise (no hook, or a head origin already has, where the hook sees nothing
# to push and checks nothing) the gate runs explicitly first.
head="$(git rev-parse HEAD)"
hook="$(git rev-parse --git-path hooks/pre-push)"
if [ -x "$hook" ] && grep -q 'run -e dev verify' "$hook" \
   && [ "$(git ls-remote origin "refs/heads/$branch" | cut -f1)" != "$head" ]; then
  git push -u origin "$branch" > "$S/$task.land-gate.log" 2>&1 \
    || { grep -q 'pre-push: verification failed' "$S/$task.land-gate.log" \
           && model "LANDING GATE FAILED: the pre-push verify is red on $branch (output in $task.land-gate.log)"
         model "push of $branch was rejected (output in $task.land-gate.log)"; }
else
  gate "$head" > "$S/$task.land-gate.log" 2>&1 \
    || model "LANDING GATE FAILED: scripts/verify.sh is red on $branch (output in $task.land-gate.log)"
  git push -q -u origin "$branch" 2>/dev/null || model "push of $branch was rejected"
fi
"$STATUS" cargo "$head" "${note:-cargo clippy + test --lib green, landing gate green}" >/dev/null 2>&1 \
  || say "WARNING: pipeline/verify not posted on $head; the PR cannot merge until it is"

if [ -z "$prs" ]; then
  B="$S/$task.pr-body.md"
  body > "$B" || model "generate_pr_body.py could not build a reviewable body"
  {
    grep -E '^out-of-scope:' <<< "$verdict" | sed 's/^/- /'
    [ -n "$verdict" ] || echo "- local build: clippy --all-targets -D warnings and cargo test --lib green; every commit is the Worker's or the Reviewer's, no Architect fix"
    [ -z "$note" ] || echo "- note: $note"
    if grep -qE '^schemas: *proved-empty' <<< "$verdict"; then
      echo "- [skip-schema-regen] the cloud verify regenerated schemas and the diff was empty"
    fi
  } >> "$B"
  body_check "$B" >/dev/null 2>&1 || model "check_pr_body.py rejected the generated body"
  "$GH" pr create --base main --head "$branch" --title "$title" --body-file "$B" >/dev/null \
    || model "gh pr create failed"
fi

# The structural postcondition: run success is not a landing, a PR is.
git ls-remote --exit-code --heads origin "$branch" >/dev/null || model "NO REMOTE BRANCH $branch after the push"
url="$("$GH" pr list --head "$branch" --state open --json url -q '.[0].url // empty')"
[ -n "$url" ] || model "NO PR for $branch after landing"

# The Dispatcher closes this Verify when the open PR carries this head.
echo "$head" > "$S/$task.landed"
rm -f "$S/$task.exit" "$S/$task.base" "$S/$task.head" "$S/$task.base-red" "$S/$task.freshness" "$S/$task.pid" "$S/$task".cloud.*
git for-each-ref --format='%(refname)' "refs/heads/cloud-verify/$task/" | xargs -r -n1 git update-ref -d
[ "$verify" = "$task" ] || rm -f "$S/$verify".{pid,exit,base,log}
say "PR confirmed: $url"
