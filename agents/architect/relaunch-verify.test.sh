#!/usr/bin/env bash
# Unit test for relaunch-verify.sh against a throwaway repo, with the cloud lane
# and the freshness check stubbed.
#
# Run: bash agents/architect/relaunch-verify.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/relaunch-verify.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache"
S="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$S"
CALLS="$DIR/offloads"
printf '#!/bin/sh\necho "$*" >> %s\nexit ${CV_RC:-0}\n' "$CALLS" > "$DIR/cv"; chmod +x "$DIR/cv"
printf '#!/bin/sh\nexit ${CODE_MOVED:-0}\n' > "$DIR/fresh"; chmod +x "$DIR/fresh"
printf '#!/bin/sh\nexit ${BUILD_LIVE:-1}\n' > "$DIR/census"; chmod +x "$DIR/census"
printf '#!/bin/sh\necho "${CLOUD_VERIFY_RESOLVE:-0} $*" >> %s\nexit ${CV_RC:-0}\n' "$CALLS" > "$DIR/cv"; chmod +x "$DIR/cv"
export RELAUNCH_CV="$DIR/cv" RELAUNCH_FRESHNESS="$DIR/fresh" RELAUNCH_CENSUS="$DIR/census"

git init -q --bare -b main "$DIR/remote.git"
git clone -q "$DIR/remote.git" "$PAPERCLIP_PROJECT" 2>/dev/null
cd "$PAPERCLIP_PROJECT"
echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main
WT="$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1"
git worktree add -q -b task/T-1 "$WT" main
(cd "$WT" && echo work > work.txt && git add work.txt && git commit -qm work)
OLD=$(git rev-parse main)

advance() { (cd "$PAPERCLIP_PROJECT" && git checkout -q main && echo "$RANDOM" >> "$1" && git add "$1" \
             && git commit -qm "main $1" && git push -q origin main); }
run() { : > "$CALLS"; bash "$SUT" T-1 T-9 "$1" >/dev/null; echo $?; }
offloads() { wc -l < "$CALLS" | tr -d ' '; }

advance base.txt
check "launch syncs and offloads" "$(run launch)" 0
check "  on top of current main" "$(cd "$WT" && git merge-base --is-ancestor origin/main HEAD && echo yes)" yes
check "  in normal mode" "$(cut -c1 "$CALLS")" 0
echo 0 > "$S/T-1.exit"
check "launch over an unread result hands it to a model" "$(run launch)" 1
rm -f "$S/T-1.exit"
check "launch beside a live local build hands it to a model" "$(BUILD_LIVE=0 run launch)" 1
check "  without offloading" "$(offloads)" 0
OLD=$(git -C "$PAPERCLIP_PROJECT" rev-parse origin/main)

echo 99 > "$S/T-1.exit"
check "retry offloads the same head" "$(run retry)" 0
check "retry removed the stale sentinel" "$([ -f "$S/T-1.exit" ] && echo kept || echo gone)" gone
check "retry passes task, branch and verify id" "$(cat "$CALLS")" "0 offload T-1 task/T-1 T-9"

check "a refused offload hands the verify to a model" "$(CV_RC=1 run retry)" 1

echo "$OLD" > "$S/T-1.base"
check "fresh with main unmoved lands" "$(run fresh)" 3
check "  without offloading" "$(offloads)" 0

advance base.txt
check "fresh after a docs-only advance lands" "$(CODE_MOVED=1 run fresh)" 3
check "  and leaves the base for Landing" "$(cat "$S/T-1.base")" "$OLD"

check "fresh after a code advance re-verifies" "$(run fresh)" 0
check "  on top of the new main" "$(cd "$WT" && git merge-base --is-ancestor origin/main HEAD && echo yes)" yes
check "  recording the new base" "$(cat "$S/T-1.base")" "$(git -C "$PAPERCLIP_PROJECT" rev-parse origin/main)"
check "  and counting the re-verify" "$(cat "$S/T-1.freshness")" 1

echo 2 > "$S/T-1.freshness"; advance base.txt
check "fresh at the cap lands" "$(run fresh)" 3
check "  without offloading" "$(offloads)" 0
rm -f "$S/T-1.freshness"

(cd "$WT" && echo conflict > base.txt && git commit -qam "branch edits base")
advance base.txt
check "a conflicting sync hands the verify to a model" "$(run fresh)" 1
check "a conflicting launch goes out in resolve mode" "$(run launch)" 0
check "  flagged as a resolve" "$(cut -c1 "$CALLS")" 1
touch "$S/T-1.cloud.resolve"
check "a conflict already sent to resolve hands it to a model" "$(run launch)" 1
rm -f "$S/T-1.cloud.resolve" "$S/T-1.exit"
check "  leaving no rebase or merge in progress" \
  "$(cd "$WT" && { [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; } && echo stuck || echo clean)" clean
(cd "$WT" && git reset -q --hard HEAD~1)

(cd "$WT" && echo dirty >> work.txt)
check "a dirty worktree hands the verify to a model" "$(run retry)" 1
(cd "$WT" && git checkout -q work.txt)

(cd "$WT" && git checkout -q -b other)
check "a worktree off its task branch hands the verify to a model" "$(run retry)" 1
(cd "$WT" && git checkout -q task/T-1)

(cd "$PAPERCLIP_PROJECT" && git checkout -q main && git merge -q --ff-only "$(git -C "$WT" rev-parse HEAD)" 2>/dev/null \
  || git -C "$PAPERCLIP_PROJECT" merge -q --no-edit task/T-1 && git -C "$PAPERCLIP_PROJECT" push -q origin main)
check "launch with nothing beyond main hands it to a model" "$(run launch)" 1

check "a missing worktree hands the verify to a model" "$(bash "$SUT" T-404 T-9 retry >/dev/null; echo $?)" 1

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
