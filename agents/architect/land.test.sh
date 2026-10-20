#!/usr/bin/env bash
# Unit test for land.sh against a throwaway repo, with relaunch-verify.sh, the
# freshness check, the cloud lane, gh, the landing gate and the PR body stubbed.
#
# Run: bash agents/architect/land.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/land.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache" PAPERCLIP_GH_USER=u
S="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$S"
CALLS="$DIR/calls"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$DIR/$1"; chmod +x "$DIR/$1"; }
stub relaunch 'echo "relaunch-verify $1: ${RELAUNCH_SAYS:-land}"; exit ${RELAUNCH_RC:-3}'
stub fresh 'exit ${CODE_MOVED:-1}'
stub cv "echo \"cv \${CLOUD_VERIFY_RESOLVE:-0} \$*\" >> $CALLS; exit \${CV_RC:-0}"
stub status "echo \"status \$*\" >> $CALLS"
stub gate "echo \"gate \$*\" >> $CALLS; exit \${GATE_RC:-0}"
stub body 'printf "## What changed\n- work\n\n## Verification\n- cargo sentinel: 0\n"'
stub check 'exit 0'
stub local 'echo "local-landable $1: ${LOCAL_SAYS:-commit abc is stamped architect}"; exit ${LOCAL_RC:-1}'
stub gh "case \"\$1 \$2\" in
  'auth switch') exit 0 ;;
  'pr create') echo \"pr-create \$*\" >> $CALLS; echo https://example/pr/1 > $DIR/open-pr ;;
  'pr list') case \"\$*\" in
      *'--state all'*) printf '%s' \"\${PRS:-}\"; [ -z \"\${PRS:-}\" ] || echo ;;
      *) cat $DIR/open-pr 2>/dev/null ;;
    esac ;;
esac"
export LAND_RELAUNCH="$DIR/relaunch" LAND_FRESHNESS="$DIR/fresh" LAND_CV="$DIR/cv" LAND_STATUS="$DIR/status" \
       LAND_GH="$DIR/gh" LAND_GATE="$DIR/gate" LAND_BODY="$DIR/body" LAND_BODY_CHECK="$DIR/check" \
       LAND_LOCAL="$DIR/local"

git init -q --bare -b main "$DIR/remote.git"
git clone -q "$DIR/remote.git" "$PAPERCLIP_PROJECT" 2>/dev/null
cd "$PAPERCLIP_PROJECT"
echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main
WT="$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1"
git worktree add -q -b task/T-1 "$WT" main
(cd "$WT" && echo work > work.txt && git add work.txt && git commit -qm work && git push -q -u origin task/T-1)

advance() { (cd "$PAPERCLIP_PROJECT" && git checkout -q main && echo "$RANDOM" >> "$1" && git add "$1" \
             && git commit -qm "main $1" && git push -q origin main); }
green() {
  rm -f "$S"/T-1.* "$DIR/open-pr"
  echo 0 > "$S/T-1.exit"
  git -C "$PAPERCLIP_PROJECT" rev-parse origin/main > "$S/T-1.base"
  printf 'CLOUD-VERIFY-V2\nresult: PASS\nschemas: %s\nout-of-scope: src/x.rs E0004 Foo -- missing arm\n' \
    "${1:-proved-empty}" > "$S/T-1.cloud.verdict"
}
run() { : > "$CALLS"; bash "$SUT" T-1 T-9 "Do the thing" > "$DIR/out" 2>&1; echo $?; }
called() { grep -c "^$1" "$CALLS" | tr -d ' '; }

echo "refusals hand the verify to a model"
green; rm "$S/T-1.cloud.verdict"
check "local build local-landable refuses -> 1" "$(run)" 1
check "  says why" "$(grep -c 'local build: local-landable T-1: commit abc is stamped architect' "$DIR/out")" 1
green; echo 1 > "$S/T-1.exit"
check "red sentinel -> 1" "$(run)" 1
green; sed -i 's/PASS/FAIL/' "$S/T-1.cloud.verdict"
check "verdict not PASS -> 1" "$(run)" 1
green; rm "$S/T-1.base"
check "no recorded base -> 1" "$(run)" 1
green; r=$(PRS="7 CLOSED" run)
check "closed PR -> 1" "$r" 1
green; echo dirty >> "$WT/work.txt"
check "dirty tree -> 1" "$(run)" 1
git -C "$WT" checkout -q -- work.txt
green; r=$(RELAUNCH_RC=1 RELAUNCH_SAYS="the cloud lane refused the offload" run)
check "relaunch refused -> 1" "$r" 1

echo "a new build goes out"
green; r=$(RELAUNCH_RC=0 RELAUNCH_SAYS="relaunched in the cloud lane" run)
check "freshness re-verify -> 2" "$r" 2
check "  and no push or PR" "$(called pr-create)" 0
green; r=$(RELAUNCH_RC=1 RELAUNCH_SAYS="neither rebase nor merge onto origin/main succeeds" run)
check "conflict -> resolve offload, 2" "$r" 2
check "  offloaded with CLOUD_VERIFY_RESOLVE=1" "$(called 'cv 1 offload T-1 task/T-1 T-9')" 1
green; : > "$S/T-1.cloud.resolve"
r=$(RELAUNCH_RC=1 RELAUNCH_SAYS="neither rebase nor merge onto origin/main succeeds" run)
check "conflict after a resolve -> 1" "$r" 1
green; r=$(CV_RC=1 RELAUNCH_RC=1 RELAUNCH_SAYS="neither rebase nor merge onto origin/main succeeds" run)
check "resolve refused -> 1" "$r" 1
check "  sentinel restored" "$(cat "$S/T-1.exit")" 0

echo "landing"
green; r=$(GATE_RC=1 run)
check "landing gate red -> 1" "$r" 1
check "  no PR" "$(called pr-create)" 0
green
check "green on current main -> 0" "$(run)" 0
check "  PR created" "$(called pr-create)" 1
check "  verify status posted" "$(called 'status cargo')" 1
check "  landed marker is the head" "$(cat "$S/T-1.landed")" "$(git -C "$WT" rev-parse HEAD)"
check "  sentinel cleared" "$([ -e "$S/T-1.exit" ] && echo present || echo gone)" gone
check "  out-of-scope fix in the body" "$(grep -c '^- out-of-scope: src/x.rs E0004' "$S/T-1.pr-body.md")" 1
check "  skip-schema-regen token in the body" "$(grep -c 'skip-schema-regen' "$S/T-1.pr-body.md")" 1
green; rm "$S/T-1.cloud.verdict"; r=$(LOCAL_RC=0 run)
check "local build with no Architect commit -> 0" "$r" 0
check "  PR created" "$(called pr-create)" 1
check "  body says it was a local build" "$(grep -c '^- local build: .*no Architect fix' "$S/T-1.pr-body.md")" 1
check "  no out-of-scope or skip token" "$(grep -cE 'out-of-scope|skip-schema-regen' "$S/T-1.pr-body.md")" 0
green not-relevant; echo https://example/pr/1 > "$DIR/open-pr"
r=$(PRS="1 OPEN" run)
check "open PR -> 0 without a second" "$r" 0
check "  no pr create" "$(called pr-create)" 0
advance base.txt
green regenerated; git -C "$PAPERCLIP_PROJECT" rev-parse origin/main~1 > "$S/T-1.base"
r=$(CODE_MOVED=0 run)
check "main moved past the cap -> 0" "$r" 0
check "  branch now contains main" "$(git -C "$WT" merge-base --is-ancestor origin/main HEAD && echo yes)" yes
check "  cap flagged in the body" "$(grep -c 'freshness cap' "$S/T-1.pr-body.md")" 1
check "  no skip token when schemas regenerated" "$(grep -c 'skip-schema-regen' "$S/T-1.pr-body.md")" 0

echo "the pre-push hook is the gate where it is installed"
mkdir -p "$DIR/hooks"
# The stub names the command land.sh looks for: pixi run -e dev verify
printf '#!/usr/bin/env bash\n# pixi run -e dev verify\nwhile read -r _ sha _ _; do echo "hook $sha" >> %s; done\n[ "${HOOK_RC:-0}" = 0 ] || { echo "pre-push: verification failed"; exit 1; }\n' \
  "$CALLS" > "$DIR/hooks/pre-push"
chmod +x "$DIR/hooks/pre-push"
git -C "$WT" config core.hooksPath "$DIR/hooks"
newhead() { (cd "$WT" && echo "$RANDOM" >> work.txt && git commit -qam more); }
newhead; green; echo https://example/pr/1 > "$DIR/open-pr"
r=$(PRS="1 OPEN" run)
check "new head with a hook -> 0" "$r" 0
check "  the hook ran on the head" "$(called "hook $(git -C "$WT" rev-parse HEAD)")" 1
check "  the explicit gate did not" "$(called gate)" 0
newhead; green
r=$(HOOK_RC=1 run)
check "hook red -> 1" "$r" 1
check "  said it was the gate" "$(grep -c 'LANDING GATE FAILED' "$DIR/out")" 1
check "  no PR" "$(called pr-create)" 0
git -C "$WT" push -q --no-verify origin task/T-1
green; echo https://example/pr/1 > "$DIR/open-pr"
r=$(PRS="1 OPEN" run)
check "head already on origin -> explicit gate, 0" "$r" 0
check "  the explicit gate ran" "$(called gate)" 1
git -C "$WT" config --unset core.hooksPath

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
