#!/usr/bin/env bash
# Unit test for publish-draft.sh against a local bare remote, with gh and
# open-draft.sh stubbed.
#
# Run: bash agents/architect/publish-draft.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/publish-draft.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj"
CALLS="$DIR/calls"
git init -q --bare -b main "$DIR/remote.git"
git init -q -b main "$PAPERCLIP_PROJECT"
g() { git -C "$PAPERCLIP_PROJECT" "$@"; }
g remote add origin "$DIR/remote.git"
g commit -q --allow-empty -m base && g push -q origin main
WT="$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1"
g worktree add -q "$WT" -b task/T-1 main
w() { git -C "$WT" "$@"; }
# Real changes: empty commits share one (empty) patch, which --cherry-pick folds together.
wc() { echo "$1" > "$WT/$1" && w add "$1" && w commit -q -m "$1"; }

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$DIR/$1"; chmod +x "$DIR/$1"; }
stub gh 'case "$1 $2" in
  "auth switch") exit 0 ;;
  "pr list") echo "${OTHERS:-0}" ;;
esac'
stub open 'echo "open $*" >> '"$CALLS"
export PUBLISH_DRAFT_GH="$DIR/gh" PUBLISH_DRAFT_OPEN="$DIR/open"

run() { : > "$CALLS"; bash "$SUT" T-1 > "$DIR/out" 2>&1; echo $?; }
remote_head() { git -C "$DIR/remote.git" rev-parse -q --verify refs/heads/task/T-1; }
opened() { grep -c '^open T-1' "$CALLS" | tr -d ' '; }

echo "nothing to show yet"
check "no commits beyond main -> 0" "$(run)" 0
check "  nothing pushed" "$(remote_head)" ""
check "  no draft" "$(opened)" 0

echo "the Worker's commit is published"
wc work
check "commit -> 0" "$(run)" 0
check "  remote carries the worktree head" "$(remote_head)" "$(w rev-parse HEAD)"
check "  draft opened" "$(opened)" 1

echo "the Reviewer's commit moves the draft"
wc review
check "second commit -> 0" "$(run)" 0
check "  remote follows" "$(remote_head)" "$(w rev-parse HEAD)"

echo "a ready, closed or merged PR is left alone"
before="$(remote_head)"
wc rework
check "other PR -> 0" "$(OTHERS=1 run)" 0
check "  not pushed" "$(remote_head)" "$before"
check "  no draft" "$(opened)" 0

echo "a commit only the remote has is never discarded"
other="$DIR/other"
git clone -q -b task/T-1 "$DIR/remote.git" "$other"
echo f > "$other/foreign" && git -C "$other" add foreign && git -C "$other" commit -q -m foreign && git -C "$other" push -q origin task/T-1
before="$(remote_head)"
check "foreign commit -> 0" "$(run)" 0
check "  not pushed" "$(remote_head)" "$before"
check "  says why" "$(grep -c 'commits the worktree lacks' "$DIR/out")" 1

echo "a rebased branch republishes"
w fetch -q origin task/T-1 && w reset -q --hard FETCH_HEAD
g commit -q --allow-empty -m main2 && g push -q origin main
w fetch -q origin main && w rebase -q origin/main
check "rebased -> 0" "$(run)" 0
check "  remote carries the rebased head" "$(remote_head)" "$(w rev-parse HEAD)"

echo "a worktree off its branch publishes nothing"
w checkout -q --detach
check "detached -> 0" "$(run)" 0
check "  says why" "$(grep -c 'is not on task/T-1' "$DIR/out")" 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
