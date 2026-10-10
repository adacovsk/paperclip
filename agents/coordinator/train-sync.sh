#!/usr/bin/env bash
# Keep stacked PRs carrying their base's conflict resolution, so a conflict with
# `main` is resolved once, at the bottom of the stack, and not again per PR.
#
# A stacked PR's branch holds its parent's commits. Until the parent's
# resolution reaches it, every PR above a conflicting base reads CONFLICTING
# against `main` too — with the parent's conflicts, not its own. Rebasing or
# porting each one replays those commits and re-hits the same conflict at
# every level. Merging the parent's tip into the child brings the resolution
# along as a commit, so a child conflicts only where its own commits touched
# the same lines.
#
# For every open PR whose base is another open PR's head branch, bottom-up:
#   - the bottom PR (base `main`) is checked with merge-tree and never written:
#     a clean bottom merges into `main` as it is, and a conflicting one is
#     reported as the single place to resolve, its whole stack held behind it;
#   - a child whose parent tip it already contains is left alone;
#   - otherwise the parent's tip is merged in (never rebased) and pushed as a
#     fast-forward. A conflict here is the child's own, and is reported.
# A PR whose base branch belongs to an already-merged PR is retargeted to
# `main`; GitHub retargets only when the base branch is deleted, and a child
# merged into a stale base branch never reaches `main` at all. A base with no
# open or merged PR is reported and left alone: retargeting it would drag
# unmerged commits into `main`.
#
# Never force-pushes. A push that loses a race to another writer fails and is
# retried on the next run against the new tip.
#
# Usage: train-sync.sh            # sync, push
#        train-sync.sh --dry-run  # report what would be merged or retargeted
# Env:   PAPERCLIP_PROJECT (the project checkout; required).
# Exit:  0 swept (including nothing to do), 2 origin/main or the PR list unreadable.
set -uo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
: "${PAPERCLIP_PROJECT:?PAPERCLIP_PROJECT must name the project checkout}"
P="$PAPERCLIP_PROJECT"
# A private worktree: the merges happen here, never in the main checkout or a
# task worktree, which belong to agents.
WT="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-train-sync/wt"

git -C "$P" fetch -q origin main 2>/dev/null
git -C "$P" rev-parse -q --verify origin/main >/dev/null \
  || { echo "train-sync: cannot read origin/main in $P" >&2; exit 2; }

PRS="$(cd "$P" && gh pr list --state open --limit 500 \
  --json number,headRefName,baseRefName,isCrossRepository)" \
  || { echo "train-sync: cannot list open PRs" >&2; exit 2; }

# Prints "<number> <head> <base>" for every PR in a stack, parents before
# children, with the bottom PR's base spelled `main`. Orphans (base is neither
# `main` nor an open head) print as "<number> <head> <base> orphan".
PLAN="$(printf '%s' "$PRS" | python3 -c '
import json, sys
prs = [p for p in json.load(sys.stdin) if not p.get("isCrossRepository")]
by_head = {p["headRefName"]: p for p in prs}
kids = {}
for p in prs:
    kids.setdefault(p["baseRefName"], []).append(p)
for p in sorted(prs, key=lambda p: p["number"]):
    b = p["baseRefName"]
    if b != "main" and b not in by_head:
        print(p["number"], p["headRefName"], b, "orphan")
def walk(p):
    print(p["number"], p["headRefName"], p["baseRefName"])
    for k in sorted(kids.get(p["headRefName"], []), key=lambda k: k["number"]):
        walk(k)
for p in sorted(prs, key=lambda p: p["number"]):
    if p["baseRefName"] == "main" and kids.get(p["headRefName"]):
        walk(p)
')"
[ -z "$PLAN" ] && exit 0

# Orphans first: a retargeted PR is a new bottom, synced on the next run.
while read -r num head base tag; do
  [ "$tag" = orphan ] || continue
  merged="$(cd "$P" && gh pr list --state merged --head "$base" --json number --jq '.[0].number // empty' 2>/dev/null)"
  if [ -z "$merged" ]; then
    echo "#$num: base $base has no open or merged PR — left alone"
  elif [ "$DRY" = 1 ]; then
    echo "#$num: would retarget to main (base $base merged as #$merged)"
  elif (cd "$P" && gh pr edit "$num" --base main >/dev/null 2>&1); then
    echo "#$num: retargeted to main (base $base merged as #$merged)"
  else
    echo "#$num: retarget to main FAILED (base $base merged as #$merged)"
  fi
done <<< "$PLAN"

refspecs=()
while read -r num head base tag; do
  [ -z "$tag" ] && refspecs+=("+refs/heads/$head:refs/remotes/origin/$head")
done <<< "$PLAN"
[ ${#refspecs[@]} -gt 0 ] && git -C "$P" fetch -q origin "${refspecs[@]}" 2>/dev/null

if [ ! -e "$WT/.git" ]; then
  git -C "$P" worktree prune
  mkdir -p "$(dirname "$WT")"
  git -C "$P" worktree add -q --detach "$WT" origin/main \
    || { echo "train-sync: cannot create worktree $WT" >&2; exit 2; }
fi

declare -A tip held prnum
while read -r num head base tag; do
  [ -z "$tag" ] || continue
  prnum[$head]="$num"
  cur="$(git -C "$P" rev-parse -q --verify "origin/$head")" \
    || { echo "#$num: origin/$head unreadable — skipped"; held[$head]=1; continue; }
  tip[$head]="$cur"

  if [ "$base" = main ]; then
    if ! out="$(git -C "$P" merge-tree --write-tree --name-only --no-messages origin/main "$cur")"; then
      held[$head]=1
      echo "#$num: bottom of stack CONFLICTS with main — resolve here (merge origin/main, do not rebase); the stack above waits on it: $(printf '%s' "$out" | sed 1d | paste -sd' ')"
    fi
    continue
  fi

  if [ -n "${held[$base]:-}" ]; then
    held[$head]=1
    echo "#$num: waits on #${prnum[$base]}"
    continue
  fi
  ptip="${tip[$base]}"
  if git -C "$P" merge-base --is-ancestor "$ptip" "$cur"; then
    continue
  fi
  if [ "$DRY" = 1 ]; then
    if out="$(git -C "$P" merge-tree --write-tree --name-only --no-messages "$ptip" "$cur")"; then
      echo "#$num: would merge #${prnum[$base]} ($base ${ptip:0:9})"
      tip[$head]="$ptip"   # descendants would then need it too
    else
      held[$head]=1
      echo "#$num: CONFLICTS with its base #${prnum[$base]} in its own commits: $(printf '%s' "$out" | sed 1d | paste -sd' ')"
    fi
    continue
  fi

  git -C "$WT" checkout -q --force --detach "$cur"
  if ! git -C "$WT" merge -q --no-edit -m "Merge $base into $head" "$ptip" >/dev/null 2>&1; then
    files="$(git -C "$WT" diff --name-only --diff-filter=U | paste -sd' ')"
    git -C "$WT" merge --abort 2>/dev/null
    held[$head]=1
    echo "#$num: CONFLICTS with its base #${prnum[$base]} in its own commits: $files"
    continue
  fi
  new="$(git -C "$WT" rev-parse HEAD)"
  if git -C "$WT" push -q origin "$new:refs/heads/$head" 2>/dev/null; then
    tip[$head]="$new"
    echo "#$num: merged #${prnum[$base]} ($base ${ptip:0:9}), pushed ${new:0:9}"
  else
    held[$head]=1
    echo "#$num: push FAILED (branch moved?) — retried next run"
  fi
done <<< "$PLAN"
exit 0
