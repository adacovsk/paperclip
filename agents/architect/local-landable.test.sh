#!/usr/bin/env bash
# Unit test for local-landable.sh against a throwaway repo.
#
# Run: bash agents/architect/local-landable.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/local-landable.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache"
S="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$S"

git init -q -b main "$PAPERCLIP_PROJECT"
cd "$PAPERCLIP_PROJECT"
echo base > base.txt && git add base.txt && git commit -qm base
WT="$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1"

commit() { (cd "$WT" && echo "$RANDOM" >> work.txt && git add work.txt && git commit -qm "$1" ${2:+-m "$2"}); }
fresh() {
  rm -rf "$S"/T-1.*; git worktree remove -f "$WT" 2>/dev/null; git branch -qD task/T-1 2>/dev/null
  git worktree add -q -b task/T-1 "$WT" main
  commit work "Stage: worker"
  commit polish "Stage: reviewer"
}
built() {
  echo 0 > "$S/T-1.exit"
  git rev-parse main > "$S/T-1.base"
  git -C "$WT" rev-parse HEAD > "$S/T-1.head"
}
run() { bash "$SUT" T-1 > "$DIR/out" 2>&1; echo $?; }

echo "landable"
fresh; built
check "worker + reviewer commits, head built -> 0" "$(run)" 0
fresh; (cd "$PAPERCLIP_PROJECT" && echo m >> base.txt && git commit -qam "main moved")
(cd "$WT" && git merge -q --no-edit main); built
check "the launch's merge onto main is not counted -> 0" "$(run)" 0

echo "not landable"
fresh; commit "fix clippy" "Stage: architect"; built
check "an Architect commit -> 1" "$(run)" 1
check "  says which commit" "$(grep -c "stamped 'architect'" "$DIR/out")" 1
fresh; commit "hand edit"; built
check "an unstamped commit -> 1" "$(run)" 1
fresh; built; commit more "Stage: reviewer"
check "head moved after the build -> 1" "$(run)" 1
fresh; built; rm "$S/T-1.head"
check "no recorded head -> 1" "$(run)" 1
fresh; built; echo 1 > "$S/T-1.exit"
check "red sentinel -> 1" "$(run)" 1
fresh; built; echo "result: PASS" > "$S/T-1.cloud.verdict"
check "a cloud verify -> 1" "$(run)" 1
rm -rf "$S"/T-1.*; git worktree remove -f "$WT"; git branch -qD task/T-1
git worktree add -q -b task/T-1 "$WT" main; built
check "no commits since the base -> 1" "$(run)" 1

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
