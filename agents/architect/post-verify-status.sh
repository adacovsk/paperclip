#!/usr/bin/env bash
# Posts the `pipeline/verify` commit status: the one record that a SHA was
# checked by the pipeline before it may merge into the project's `main`.
#
# WHY A STATUS ON THE SHA. A verify speaks for the exact commit it built. A
# commit pushed onto the branch after it — an operator fix-up, a "small" edit
# written where cargo does not run — inherits nothing, and nothing else on a PR
# says so: the old green comment still reads as current. A status is keyed on
# the SHA, so a new head starts with none, and branch protection requiring this
# context turns "merged past an unbuilt commit" into an explicit `--admin`
# override instead of an accident. It is a status, not a workflow, so it costs
# no Actions minutes and a billing outage cannot reject it.
#
# Only a path that actually checked the SHA posts, and each mode states what
# that check was:
#   cargo   <sha> <desc>            the caller ran cargo clippy and test --lib
#                                   green on exactly <sha> (plus the landing gate)
#   nocargo <sha> <desc>            the caller ran the landing gate on <sha>, and
#                                   the diff from main touches nothing cargo
#                                   builds — refused otherwise, because a gate
#                                   that never compiles cannot vouch for Rust
#   carry   <new> <from> <desc>     <new> has the same tree as <from>, and <from>
#                                   already carries a green pipeline/verify — a
#                                   republish of verified bytes under a new commit
#                                   (e.g. a merge commit whose tree is the tip)
#
# Exit: 0 posted, 1 refused (nothing posted), 2 usage, 3 the post itself failed.
# The repository is the clone's own `origin`, spelled out for the `gh` call: a
# bare `gh` in a fork resolves to the upstream parent and posts there.
# Env: PIPELINE_VERIFY_REPO (owner/name; default from origin),
#      PIPELINE_VERIFY_URL (optional target_url, e.g. the task link).
set -u

CONTEXT=pipeline/verify
REPO="${PIPELINE_VERIFY_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@|https://)github\.com[:/]##; s#\.git$##')}"
# Paths cargo reads. A diff touching none of them cannot change what compiles.
RUST_PATHS='(\.rs$|(^|/)Cargo\.(toml|lock)$|(^|/)build\.rs$|^rust-toolchain|^\.cargo/)'

die() { echo "post-verify-status: $1" >&2; exit "${2:-1}"; }
usage() { die "usage: post-verify-status.sh cargo|nocargo <sha> <desc> | carry <new> <from> <desc>" 2; }

full() { git rev-parse -q --verify "$1^{commit}" 2>/dev/null || die "not a commit: $1" 2; }

base_of() {
  git rev-parse -q --verify origin/main >/dev/null || die "origin/main unreadable — fetch first" 2
  git merge-base origin/main "$1" 2>/dev/null || die "no merge base between $1 and origin/main" 2
}

post() {
  local sha="$1" desc="$2"
  [ -n "$REPO" ] || die "cannot resolve the repository from origin; set PIPELINE_VERIFY_REPO" 2
  local base; base="$(base_of "$sha")" || exit $?
  desc="$desc (main ${base:0:9})"
  local args=(-X POST "repos/$REPO/statuses/$sha" -f context="$CONTEXT"
    -f state=success -f description="${desc:0:140}")
  [ -n "${PIPELINE_VERIFY_URL:-}" ] && args+=(-f target_url="$PIPELINE_VERIFY_URL")
  gh api "${args[@]}" >/dev/null || die "could not post $CONTEXT on $sha" 3
  echo "posted $CONTEXT success on ${sha:0:9}"
}

mode="${1:-}"
case "$mode" in
  cargo)
    [ $# -eq 3 ] || usage
    sha="$(full "$2")" || exit $?
    post "$sha" "$3" ;;
  nocargo)
    [ $# -eq 3 ] || usage
    sha="$(full "$2")" || exit $?
    base="$(base_of "$sha")" || exit $?
    rust="$(git diff --name-only "$base" "$sha" | grep -E "$RUST_PATHS")"
    [ -z "$rust" ] || die "refused: the diff touches what cargo builds, so the landing gate alone cannot vouch for it: $(echo $rust | cut -c1-200)"
    post "$sha" "$3" ;;
  carry)
    [ $# -eq 4 ] || usage
    new="$(full "$2")" || exit $?
    from="$(full "$3")" || exit $?
    [ "$(git rev-parse "$new^{tree}")" = "$(git rev-parse "$from^{tree}")" ] \
      || die "refused: ${new:0:9} and ${from:0:9} have different trees, so the verify of one says nothing about the other"
    [ -n "$REPO" ] || die "cannot resolve the repository from origin; set PIPELINE_VERIFY_REPO" 2
    state="$(gh api "repos/$REPO/commits/$from/status" \
      --jq ".statuses[] | select(.context == \"$CONTEXT\") | .state" 2>/dev/null)"
    [ "$state" = success ] || die "refused: ${from:0:9} carries no green $CONTEXT (got '${state:-none}')"
    post "$new" "$4" ;;
  *) usage ;;
esac
