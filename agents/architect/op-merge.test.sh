#!/usr/bin/env bash
# Unit test for op-merge.sh against a throwaway repo, with gh, land.sh,
# relaunch-verify.sh and the build census stubbed.
#
# Run: bash agents/architect/op-merge.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/op-merge.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }
has() { grep -qF -- "$2" <<< "$OUT" && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                                   || { FAIL=$((FAIL+1)); printf '  FAIL %s (no "%s" in: %s)\n' "$1" "$2" "$OUT"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache"
S="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$S"
CALLS="$DIR/calls"

# origin, a clone standing in for the project, and the task's worktree.
git init -q --bare -b main "$DIR/origin.git"
git clone -q "$DIR/origin.git" "$PAPERCLIP_PROJECT" 2>/dev/null
cd "$PAPERCLIP_PROJECT"
echo a > f; git add f; git commit -qm base; git push -q origin main
mkdir -p .paperclip/worktrees
git worktree add -q -b task/T-1 .paperclip/worktrees/T-1
( cd .paperclip/worktrees/T-1 && echo b > g && git add g && git commit -qm work && git push -q origin task/T-1 )
SHA="$(git -C .paperclip/worktrees/T-1 rev-parse HEAD)"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$DIR/$1"; chmod +x "$DIR/$1"; }
# `gh pr view` answers from PR_*; `gh api .../status` from STATUS (re-read from a
# file so a stubbed landing can turn it green mid-run).
stub gh "case \"\$1 \$2\" in
  'pr view') printf '%s\t%s\t%s\t%s\t%s\t%s\n' \"\${PR_STATE:-OPEN}\" \"\${PR_HEAD:-task/T-1}\" \"$SHA\" \"\${PR_MERGEABLE:-MERGEABLE}\" \"\${PR_DRAFT:-false}\" 'T-1 title' ;;
  'pr merge') echo \"merge \$*\" >> $CALLS; exit \${MERGE_RC:-0} ;;
  api*) cat $DIR/status 2>/dev/null ;;
esac"
stub land "echo \"land \$*\" >> $CALLS; [ -z \"\${LAND_GREENS:-}\" ] || echo success > $DIR/status; echo \"land \$1: \${LAND_SAYS:-PR confirmed}\"; exit \${LAND_RC:-0}"
stub relaunch "echo \"relaunch \$* lane=\$ARCHITECT_CLOUD_LANE\" >> $CALLS; echo \"relaunch-verify \$1: \${RELAUNCH_SAYS:-relaunched in the cloud lane (first launch)}\"; exit \${RELAUNCH_RC:-0}"
stub census 'exit ${CENSUS_RC:-1}'
export OP_MERGE_GH="$DIR/gh" OP_MERGE_LAND="$DIR/land" OP_MERGE_RELAUNCH="$DIR/relaunch" OP_MERGE_CENSUS="$DIR/census"

run() { : > "$CALLS"; OUT="$(env "$@" bash "$SUT" 7 2>&1)"; RC=$?; }
reset() { rm -f "$DIR/status" "$S"/T-1.*; }

echo "a green head merges, pinned to the SHA that was built"
reset; echo success > "$DIR/status"
run; check "exit" "$RC" 0
check "merge call" "$(cat "$CALLS")" "merge pr merge 7 --repo $DIR/origin --merge --match-head-commit $SHA"

echo "a green draft is not merged; landing never marked it ready"
reset; echo success > "$DIR/status"
run PR_DRAFT=true; check "exit" "$RC" 1
check "no merge" "$(grep -c '^merge' "$CALLS")" 0
has "says it is still a draft" "still a draft"

echo "a draft with no status is built like any other head"
reset
run PR_DRAFT=true; check "exit" "$RC" 3
check "launched" "$(cut -d' ' -f1 "$CALLS")" "relaunch"

echo "a head with no status is built, not merged"
reset
run; check "exit" "$RC" 3
check "launched, cloud lane on by default" "$(cat "$CALLS")" "relaunch T-1 T-1 launch lane=1"
has "says where it went" "relaunched in the cloud lane"

echo "the lane flag is the caller's to turn off"
reset
run ARCHITECT_CLOUD_LANE=0; check "lane=0 is passed through" "$(cat "$CALLS")" "relaunch T-1 T-1 launch lane=0"

echo "a failed or pending status is not green"
reset; echo failure > "$DIR/status"
run; check "exit" "$RC" 3
check "no merge" "$(grep -c '^merge' "$CALLS")" 0

echo "green but conflicting with main is built again"
reset; echo success > "$DIR/status"
run PR_MERGEABLE=CONFLICTING; check "exit" "$RC" 3
check "relaunched, not merged" "$(cut -d' ' -f1 "$CALLS")" "relaunch"

echo "green with mergeability not computed waits"
reset; echo success > "$DIR/status"
run PR_MERGEABLE=UNKNOWN; check "exit" "$RC" 3
check "nothing called" "$(wc -l < "$CALLS")" 0

echo "a stale resolve marker does not block the launch"
reset; : > "$S/T-1.cloud.resolve"
run; check "exit" "$RC" 3
check "marker cleared" "$([ -e "$S/T-1.cloud.resolve" ] && echo kept || echo cleared)" cleared

echo "a build already out is left alone"
reset
run CENSUS_RC=0; check "exit" "$RC" 3
check "nothing called" "$(wc -l < "$CALLS")" 0
has "says so" "a verify of T-1 is out"

echo "a pid file left by a finished watcher is not a build, and says nothing"
reset; echo 999999999 > "$S/T-1.pid"
run; check "exit" "$RC" 3
check "launched" "$(cut -d' ' -f1 "$CALLS")" "relaunch"
check "no stray error" "$(grep -c 'No such file' <<< "$OUT")" 0

echo "a green sentinel is landed, then merged once the status is posted"
reset; echo 0 > "$S/T-1.exit"
run LAND_GREENS=1; check "exit" "$RC" 0
check "landed then merged" "$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ')" "land merge "

echo "a landing that posted nothing does not merge and does not loop"
reset; echo 0 > "$S/T-1.exit"
run; check "exit" "$RC" 1
check "landed once" "$(grep -c '^land' "$CALLS")" 1
has "says why" "still has no green pipeline/verify"

echo "a landing that sent a new build out is a wait"
reset; echo 0 > "$S/T-1.exit"
run LAND_RC=2 LAND_SAYS="conflicts with origin/main; sent to the cloud lane in resolve mode"; check "exit" "$RC" 3

echo "a landing that needs a model is reported"
reset; echo 0 > "$S/T-1.exit"
run LAND_RC=1 LAND_SAYS="LANDING GATE FAILED"; check "exit" "$RC" 1
has "carries the line" "LANDING GATE FAILED"

echo "a red sentinel is read, not rebuilt"
reset; echo 101 > "$S/T-1.exit"
run; check "exit" "$RC" 1
check "nothing called" "$(wc -l < "$CALLS")" 0

echo "both lanes refusing is reported"
reset
run RELAUNCH_RC=1 RELAUNCH_SAYS="the cloud lane refused the resolve offload"; check "exit" "$RC" 1

echo "a commit only the PR carries is never pushed over"
reset
git clone -q "$DIR/origin.git" "$DIR/other" 2>/dev/null
( cd "$DIR/other" && git checkout -q task/T-1 && echo c > h && git add h && git commit -qm "pushed from elsewhere" && git push -q origin task/T-1 )
run; check "exit" "$RC" 1
check "not launched" "$(wc -l < "$CALLS")" 0
has "names the gap" "carries commits the worktree lacks"
git -C "$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1" merge -q --ff-only origin/task/T-1

echo "only task branches, only open PRs"
reset; echo success > "$DIR/status"
run PR_HEAD=op/thing; check "op branch refused" "$RC" 1
run PR_STATE=MERGED; check "merged PR refused" "$RC" 1
check "no merge attempted" "$(wc -l < "$CALLS")" 0

echo "several PRs: one waiting does not stop the next, and the worst result wins"
reset; echo success > "$DIR/status"
: > "$CALLS"; OUT="$(MERGE_RC=1 bash "$SUT" 7 8 2>&1)"; RC=$?
check "exit" "$RC" 1
check "both tried" "$(grep -c '^merge' "$CALLS")" 2

echo "no arguments is usage"
bash "$SUT" >/dev/null 2>&1; check "exit" "$?" 2

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
