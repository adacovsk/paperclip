#!/usr/bin/env bash
# Unit test for local-verify.sh: a real detached launch against a throwaway repo,
# with cargo-sem.sh and the sentinel callback stubbed and the systemd scope off.
#
# Run: bash agents/architect/local-verify.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/local-verify.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache" LOCAL_VERIFY_SCOPE=0
S="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$S"
# The chain checks for cargo and sccache before it builds; neither runs here.
mkdir -p "$DIR/bin"; printf '#!/bin/sh\nexit 0\n' > "$DIR/bin/cargo"; cp "$DIR/bin/cargo" "$DIR/bin/sccache"
chmod +x "$DIR/bin/cargo" "$DIR/bin/sccache"; export PATH="$DIR/bin:$PATH"
# The generator stub writes GEN_OUT (if set) into assets/schemas/, as a real
# regeneration that moved a schema would.
printf '#!/bin/sh\necho "sem $*" >> %s\necho "prio=${CARGO_SEM_PRIORITY:-none}" >> %s\ncase "$*" in *generate_schemas*) [ -z "${GEN_OUT:-}" ] || echo "$GEN_OUT" > assets/schemas/a.schema.json; exit ${GEN_RC:-0};; esac\nexit ${SEM_RC:-0}\n' \
  "$DIR/calls" "$DIR/calls" > "$DIR/sem"
printf '#!/bin/sh\necho "callback $*" >> %s\n' "$DIR/calls" > "$DIR/cb"
chmod +x "$DIR/sem" "$DIR/cb"
export LOCAL_VERIFY_SEM="$DIR/sem" LOCAL_VERIFY_CALLBACK="$DIR/cb"

git init -q --bare -b main "$DIR/remote.git"
git clone -q "$DIR/remote.git" "$PAPERCLIP_PROJECT" 2>/dev/null
cd "$PAPERCLIP_PROJECT"
# The schema guard stub: exit 1 (schema-relevant) when SCHEMA_RELEVANT=1.
mkdir -p scripts assets/schemas && printf 'import os, sys\nsys.exit(int(os.environ.get("SCHEMA_RELEVANT", "0")))\n' > scripts/check_schema_regen.py
echo '{}' > assets/schemas/a.schema.json
echo base > base.txt && git add base.txt scripts assets && git commit -qm base && git push -q origin main
WT="$PAPERCLIP_PROJECT/.paperclip/worktrees/T-1"
git worktree add -q -b task/T-1 "$WT" main
(cd "$WT" && echo work > work.txt && git add work.txt && git commit -qm work)
(git checkout -q main && echo more >> base.txt && git commit -qam "main moved" && git push -q origin main)

# Wait for the detached chain: it writes the sentinel last but one, then calls back.
settle() { for _ in $(seq 100); do grep -q '^callback' "$DIR/calls" 2>/dev/null && return; sleep 0.1; done; }
launch() { rm -f "$S"/T-1.* "$S"/V-2.*; : > "$DIR/calls"; bash "$SUT" T-1 V-2 "$@" > "$DIR/out" 2>&1; echo $?; }

echo "launch"
check "launches -> 0" "$(launch)" 0
settle
check "  sentinel is cargo's result" "$(cat "$S/T-1.exit")" 0
check "  built on current main" "$(cat "$S/T-1.base")" "$(git rev-parse origin/main)"
check "  recorded the head it built" "$(cat "$S/T-1.head")" "$(git -C "$WT" rev-parse HEAD)"
check "  the head sits on main" "$(git -C "$WT" merge-base --is-ancestor origin/main HEAD && echo yes)" yes
check "  clippy then test, one cargo per slot" "$(grep -c '^sem env CARGO_INCREMENTAL=0 cargo' "$DIR/calls")" 2
check "  normal lane" "$(grep -c '^prio=none' "$DIR/calls")" 2
check "  called back for the verify" "$(grep '^callback' "$DIR/calls")" "callback V-2"
check "  verify-id aliases" "$(readlink "$S/V-2.exit")" "$S/T-1.exit"
check "  the launch is on disk before the chain runs" "$(grep -c '^local-verify: launching T-1 for V-2' "$S/T-1.log")" 1
check "--express -> express lane" "$(launch --express >/dev/null; settle; grep -c '^prio=1' "$DIR/calls")" 2
r=$(SEM_RC=101 launch); settle
check "a red build -> launched, sentinel 101" "$r $(cat "$S/T-1.exit")" "0 101"
check "  test skipped after a red clippy" "$(grep -c '^sem' "$DIR/calls")" 1
check "  not schema-relevant -> recorded, no regeneration" "$(launch >/dev/null; settle; cat "$S/T-1.schemas"; grep -c generate_schemas "$DIR/calls")" "not-relevant
0"

echo "schemas"
r=$(SCHEMA_RELEVANT=1 launch); settle
check "relevant, no change -> proved-empty, then the test" "$r $(cat "$S/T-1.schemas") $(cat "$S/T-1.exit")" "0 proved-empty 0"
check "  clippy, generate_schemas, test: three slots in order" "$(grep '^sem' "$DIR/calls" | sed 's/.*cargo //' | cut -d' ' -f1-3 | tr '\n' '|')" "clippy --all-targets --|run --bin generate_schemas|test --lib|"
check "  nothing committed" "$(git -C "$WT" log -1 --format=%s)" "work"
r=$(SCHEMA_RELEVANT=1 GEN_OUT='{"changed":1}' launch); settle
check "relevant, schemas moved -> regenerated" "$r $(cat "$S/T-1.schemas") $(cat "$S/T-1.exit")" "0 regenerated 0"
check "  committed as the Architect's" "$(git -C "$WT" log -1 --format='%s %(trailers:key=Stage,valueonly)' | tr -d '\n')" "chore: regenerate schemas architect"
check "  the recorded head is the regenerated commit the test built" "$(cat "$S/T-1.head")" "$(git -C "$WT" rev-parse HEAD)"
check "  the tree is clean" "$(git -C "$WT" status --porcelain)" ""
r=$(SCHEMA_RELEVANT=1 GEN_RC=101 launch); settle
check "a failing generator -> red, test skipped" "$r $(cat "$S/T-1.exit") $(grep -c 'test --lib' "$DIR/calls")" "0 101 0"
check "  no schema result recorded" "$([ -e "$S/T-1.schemas" ] && echo yes || echo no)" no

echo "refusals"
launch >/dev/null; settle
check "a sentinel already present -> 1" "$(bash "$SUT" T-1 V-2 >/dev/null 2>&1; echo $?)" 1
check "an id that is not one -> 1" "$(bash "$SUT" 'T-1;rm' V-2 >/dev/null 2>&1; echo $?)" 1
check "an unknown option -> 1" "$(rm -f "$S"/T-1.*; bash "$SUT" T-1 V-2 --fast >/dev/null 2>&1; echo $?)" 1
rm -rf "$WT"; git worktree prune
check "a missing worktree -> launched, sentinel 97" "$(launch >/dev/null; settle; cat "$S/T-1.exit")" 97

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
