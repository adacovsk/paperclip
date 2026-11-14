#!/usr/bin/env bash
# Open the draft PR for a task branch: when the Worker's stage ends
# (publish-draft.sh, from the Dispatcher), and again when its verify launches.
#
# WHY. A PR used to open only at landing, after a green build, so the work was
# invisible while it built and a conflict with main surfaced only when landing
# tried to sync. A draft opened at launch gives the reviewer the change to read
# and GitHub a head to report mergeability on. It cannot land anything: GitHub
# refuses to merge a draft, and the Dispatcher's `open_pr_heads` leaves drafts
# out, so a draft never closes the Verify. land.sh gives the draft its real body
# and marks it ready on the green build.
#
# Best effort by design. The caller has already pushed the branch (and, from
# the cloud lane, launched the build); a draft that fails to open costs only its early visibility, because
# land.sh opens the PR itself when none exists. So every failure exits 0 with a
# line saying why, and the build is never held for it.
#
# Usage:  open-draft.sh <task-id>   (from the task's worktree)
# Env:    PAPERCLIP_PROJECT (default: the checkout this worktree belongs to,
#         since cloud-verify.sh's watcher runs in a scope that does not inherit
#         it), PAPERCLIP_GH_USER, PAPERCLIP_API_URL,
#         PAPERCLIP_API_KEY; OPEN_DRAFT_GH / OPEN_DRAFT_TITLE / OPEN_DRAFT_BODY /
#         OPEN_DRAFT_CHECK are test seams.
set -uo pipefail

task="${1:?task id}"
branch="task/$task"
PROJECT="${PAPERCLIP_PROJECT:-$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")}"
GH="${OPEN_DRAFT_GH:-gh}"
API="${PAPERCLIP_API_URL:-http://localhost:3100}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"

say() { echo "open-draft $task: $*"; exit 0; }
[ -d "$PROJECT/scripts" ] || say "no project checkout at '$PROJECT'; no draft"

title() {
  if [ -n "${OPEN_DRAFT_TITLE:-}" ]; then "$OPEN_DRAFT_TITLE" "$task"; return; fi
  curl -sSf ${PAPERCLIP_API_KEY:+-H "Authorization: Bearer $PAPERCLIP_API_KEY"} "$API/api/issues/$task" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["title"])'
}
body() {
  if [ -n "${OPEN_DRAFT_BODY:-}" ]; then "$OPEN_DRAFT_BODY" "$task"; return; fi
  ( cd "$PROJECT" && pixi run -e dev python scripts/generate_pr_body.py "$task" --draft )
}
body_check() {
  if [ -n "${OPEN_DRAFT_CHECK:-}" ]; then "$OPEN_DRAFT_CHECK" "$1" "$2"; return; fi
  ( cd "$PROJECT" && pixi run -e dev python scripts/check_pr_body.py \
      --head-ref "$branch" --title "$1" --body-file "$2" --draft )
}

[ -n "${PAPERCLIP_GH_USER:-}" ] && { "$GH" auth switch --user "$PAPERCLIP_GH_USER" >/dev/null 2>&1 || true; }

# Any PR at all (open, draft, closed or merged) is someone's decision already;
# a second one for the same branch would split the review.
prs="$("$GH" pr list --head "$branch" --state all --json number -q 'length')" || say "cannot list PRs for $branch; no draft"
[ "$prs" = 0 ] || say "a PR for $branch already exists; no draft"

t="$(title)" && [ -n "$t" ] || say "cannot read the task title; no draft"
mkdir -p "$S"
B="$S/$task.draft-body.md"
body > "$B" 2>/dev/null || say "generate_pr_body.py --draft could not build a body; no draft"
body_check "$t" "$B" >/dev/null 2>&1 || say "check_pr_body.py --draft rejected the body; no draft"
url="$("$GH" pr create --draft --base main --head "$branch" --title "$t" --body-file "$B")" \
  || say "gh pr create --draft failed; land.sh will open the PR"
say "draft opened: $url"
