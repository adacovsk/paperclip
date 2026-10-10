#!/usr/bin/env bash
# Merge gate for a merge train: a stack of `train/<n>/<task>` PRs, each based on
# `main`, each head containing the one below it. The stack merges only when the
# exact tree it will put on `main` has a green cargo verify.
#
# WHY THE TREE AND NOT THE BRANCHES. Each train PR can be green on its own and
# the stack still land red: once `main` moves, the merges that land are new
# trees nobody compiled. Resolving a conflict at merge time (an `op/resolve-*`
# branch merged straight into the PR) is the same failure with extra steps —
# two branches that each added the same import, or each registered one more
# observer against a test that counts them, merge without a textual conflict
# and do not compile. So the record is keyed on the tree of
# `merge(origin/main, top)`: if `main` moves, or any PR head moves, or a
# resolution is pushed, the tree changes and the record no longer applies.
# Never conflict-resolve a train PR at merge time; resolve on the train branch,
# push, and verify again.
#
# Usage (from a clone of the project, PRs bottom to top):
#   train-gate.sh tree   <pr>...   print the tree the stack would put on main
#   train-gate.sh verify <pr>...   build that tree under cargo-sem.sh; record it when green
#   train-gate.sh check  <pr>...   exit 0 only if the current tree has a green record
#   train-gate.sh merge  <pr>...   check, then merge bottom to top, refusing if main moves
#
# Exit codes:
#   0   green / merged
#   1   verify ran and was red (the log path is printed)
#   2   usage
#   3   no green record for the current tree — verify it first
#   4   the stack itself is unfit: a PR is not open, heads do not stack, or the
#       merge onto main conflicts (resolve on the train branch, never at merge)
#   5   main moved while merging; the PRs after the last one merged are left open
#   6   merged, but main's tree is not the verified one — verify main now
set -uo pipefail

# The repository is the clone's own `origin`, spelled out for every `gh` call:
# a bare `gh` in a fork resolves to the upstream parent and acts there.
REPO="${TRAIN_GATE_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@|https://)github\.com[:/]##; s#\.git$##')}"
GATE_DIR="${TRAIN_GATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify/train-gate}"
SEM="${TRAIN_GATE_SEM:-$(cd "$(dirname "$0")" && pwd)/cargo-sem.sh}"

die() { printf 'train-gate: %s\n' "$1" >&2; exit "${2:-4}"; }

# Sets HEADS (bottom to top), MAIN and TREE for the PRs given, after checking
# every PR is open and each head contains the one below it.
resolve_stack() {
  [ "$#" -ge 1 ] || die "name the train's PRs, bottom to top" 2
  local n state oid prev="" refs=()
  HEADS=(); PRS=("$@")
  for n in "$@"; do refs+=("+refs/pull/$n/head:refs/train-gate/pr/$n"); done
  git fetch -q origin main "${refs[@]}" || die "cannot fetch main and the PR heads"
  for n in "$@"; do
    read -r state oid < <(gh pr view "$n" --repo "$REPO" --json state,headRefOid --jq '.state + " " + .headRefOid')
    [ "$state" = OPEN ] || die "PR #$n is ${state:-unreadable}, not OPEN"
    [ "$(git rev-parse -q --verify "refs/train-gate/pr/$n")" = "$oid" ] \
      || die "PR #$n head $oid does not match what was fetched — it moved; run again"
    if [ -n "$prev" ]; then
      git merge-base --is-ancestor "$prev" "$oid" || die "PR #$n does not contain the PR below it; list the stack bottom to top"
    fi
    HEADS+=("$oid"); prev="$oid"
  done
  MAIN="$(git rev-parse origin/main)"
  TREE="$(git merge-tree --write-tree "$MAIN" "$prev" 2>/dev/null | head -1)" \
    || die "the stack conflicts with origin/main ($MAIN); resolve on the train branch, push, verify again"
  [ -n "$TREE" ] || die "could not compute the merged tree"
}

record_path() { printf '%s/%s.green' "$GATE_DIR" "$1"; }

cmd_tree() { resolve_stack "$@"; printf '%s\n' "$TREE"; }

# Builds a commit carrying the merged tree in a scratch worktree and runs the
# Architect's two gates on it, each its own `cargo-sem.sh` slot (the wrapper
# refuses a chain inside one). Same flags as the Architect's verify, so a green
# here means what a green Verify means.
cmd_verify() {
  resolve_stack "$@"
  mkdir -p "$GATE_DIR"
  local top="${HEADS[-1]}" commit wt log rc
  commit="$(git commit-tree "$TREE" -p "$MAIN" -p "$top" -m "train-gate: main + PR #${PRS[-1]}")" \
    || die "cannot build the merge commit"
  wt="$GATE_DIR/wt-$TREE"; log="$GATE_DIR/$TREE.log"
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  git worktree add -q --detach "$wt" "$commit" || die "cannot create the verify worktree"
  echo "verifying tree $TREE (main ${MAIN:0:9} + PR #${PRS[-1]} ${top:0:9}); log: $log"
  (
    cd "$wt" || exit 97
    "$SEM" env CARGO_INCREMENTAL=0 cargo clippy --all-targets -- -D warnings -A dead-code -A unused-imports \
      && CARGO_SEM_CGU_DIV=2 "$SEM" env CARGO_INCREMENTAL=0 cargo test --lib
  ) > "$log" 2>&1
  rc=$?
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ]; then
    echo "RED (exit $rc): fix on the train branch, push, verify again. Log: $log"
    return 1
  fi
  {
    printf 'main: %s\n' "$MAIN"
    printf 'pr: %s\n' "${PRS[@]}"
    printf 'head: %s\n' "${HEADS[@]}"
  } > "$(record_path "$TREE")"
  echo "GREEN: tree $TREE recorded"
}

cmd_check() {
  resolve_stack "$@"
  [ -f "$(record_path "$TREE")" ] \
    || die "no green verify for tree $TREE (main ${MAIN:0:9} + PR #${PRS[-1]}); run: train-gate.sh verify ${PRS[*]}" 3
  echo "green: tree $TREE"
}

# Merges bottom to top. `--match-head-commit` refuses a PR whose head moved
# after the check, and each landed merge must sit directly on the one before
# it: anything else merged into main in between means the tree being built is
# no longer the verified one, so the rest of the stack stays open.
cmd_merge() {
  cmd_check "$@" || exit $?
  local i n prev="$MAIN" now
  for i in "${!PRS[@]}"; do
    n="${PRS[$i]}"
    gh pr merge "$n" --repo "$REPO" --merge --match-head-commit "${HEADS[$i]}" >/dev/null \
      || die "merging PR #$n failed; PRs from #$n up are still open" 5
    git fetch -q origin main || die "cannot read main after merging PR #$n" 5
    now="$(git rev-parse origin/main)"
    if [ "$(git rev-parse -q --verify "$now^1")" != "$prev" ] || [ "$(git rev-parse -q --verify "$now^2")" != "${HEADS[$i]}" ]; then
      die "main moved under the stack at PR #$n (now ${now:0:9}); remaining PRs left open — verify again" 5
    fi
    echo "merged PR #$n -> ${now:0:9}"
    prev="$now"
  done
  [ "$(git rev-parse "$prev^{tree}")" = "$TREE" ] \
    || die "merged, but main's tree $(git rev-parse "$prev^{tree}") is not the verified $TREE — verify main now" 6
  echo "main ${prev:0:9} carries the verified tree $TREE"
}

case "${1:-}" in
  tree)   shift; cmd_tree   "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  check)  shift; cmd_check  "$@" ;;
  merge)  shift; cmd_merge  "$@" ;;
  *) sed -n '/^# Usage/,/^# Exit codes/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
