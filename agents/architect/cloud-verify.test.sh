#!/usr/bin/env bash
# Unit test for cloud-verify.sh's verdict parsing and launch preconditions.
#
# Everything here is stubbed — no cloud session is created, no ref is pushed,
# no network is touched. What is under test is the part that decides what a
# verdict MEANS, because that is where a wrong answer is expensive: reading
# "the VM never answered" as "the build failed" sends a green branch back to a
# Worker, and reading a stale verdict as current lands unverified code.
#
# Run: bash agents/architect/cloud-verify.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CV="$HERE/cloud-verify.sh"
DIR="$(mktemp -d)"
BIN="$DIR/bin"; mkdir -p "$BIN"
export CLOUD_VERIFY_DIR="$DIR/state"; mkdir -p "$CLOUD_VERIFY_DIR"
export PATH="$BIN:$PATH"

trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s (%s)\n' "$1" "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected $3, got $2"; }

# --- stubs -----------------------------------------------------------------
# The verdict is a commit message on a ref under refs/heads/cloud-verify/. `make_git`
# takes the ref name the remote is pretending to have published ("" = none yet).
make_git() {
  cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls-remote)  [ -n "$1" ] && [ "\$3" = "$1" ] && echo "deadbee\trefs/x"; exit 0 ;;
  fetch)      exit 0 ;;
  log)        cat "$DIR/body.txt"; exit 0 ;;
  rev-parse)  echo bbb222; exit 0 ;;
  *)          exit 0 ;;
esac
EOF
  chmod +x "$BIN/git"
}
seed_state() {  # task, ref, launched-epoch
  printf '%s\n' "$2" > "$CLOUD_VERIFY_DIR/$1.cloud.ref"
  printf '%s\n' "$3" > "$CLOUD_VERIFY_DIR/$1.cloud.launched"
}
verdict() {     # result-line
  cat > "$DIR/body.txt" <<EOF
CLOUD-VERIFY-V1
task: AA-1
branch: task/AA-1
base: aaa111
head: bbb222
result: $1
cmd: cargo clippy --all-targets = 0
--- errors ---
EOF
}

REF="refs/heads/cloud-verify/AA-1/bbb222"
NOW="$(date +%s)"

echo "verdict parsing:"
seed_state AA-1 "$REF" "$NOW"
make_git "$REF"

verdict PASS;  "$CV" poll AA-1 >/dev/null 2>&1; check "PASS  -> 0"  "$?" 0
verdict FAIL;  "$CV" poll AA-1 >/dev/null 2>&1; check "FAIL  -> 1"  "$?" 1
verdict STALE; "$CV" poll AA-1 >/dev/null 2>&1; check "STALE -> 98" "$?" 98
# A truncated or malformed body must never read as green.
printf 'CLOUD-VERIFY-V1\ntask: AA-1\n' > "$DIR/body.txt"
"$CV" poll AA-1 >/dev/null 2>&1;               check "garbage -> 99" "$?" 99

echo "timing:"
verdict PASS
make_git ""                                      # no verdict pushed yet
seed_state AA-1 "$REF" "$NOW"
"$CV" poll AA-1 >/dev/null 2>&1;               check "pending inside deadline -> 75" "$?" 75
seed_state AA-1 "$REF" "$((NOW - 99999))"
"$CV" poll AA-1 >/dev/null 2>&1;               check "past deadline -> 99"           "$?" 99

echo "staleness:"
# A verdict for the SAME task at a DIFFERENT head must not be matched. This is
# the case that would otherwise land unverified code: the branch was pushed
# again after the cloud session started.
seed_state AA-1 "refs/heads/cloud-verify/AA-1/ccc333" "$NOW"
make_git "$REF"
"$CV" poll AA-1 >/dev/null 2>&1;               check "different head not published -> 75" "$?" 75
# Substring collision: AA-1 must not pick up AA-12's verdict.
seed_state AA-1 "$REF" "$NOW"
make_git "refs/heads/cloud-verify/AA-12/bbb222"
"$CV" poll AA-1 >/dev/null 2>&1;               check "AA-12 ref not matched by AA-1 -> 75" "$?" 75

echo "launch preconditions:"
"$CV" poll AA-404 >/dev/null 2>&1;             check "poll before launch -> 96" "$?" 96
make_git ""
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "ls-remote" ] && exit 2   # branch absent from origin
exit 0
EOF
chmod +x "$BIN/git"
"$CV" launch AA-2 task/AA-2 >/dev/null 2>&1;   check "unpushed branch -> 98" "$?" 98

echo "watch writes a sentinel on every path:"
# The one property that must never fail. A watch that exits without writing
# $task.exit is indistinguishable from "still building", which is the strand the
# 99 sentinel was introduced to eliminate.
export CLOUD_VERIFY_POLL=0
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "ls-remote" ] && exit 2   # unpushed -> launch dies with 98
exit 0
EOF
chmod +x "$BIN/git"
rm -f "$CLOUD_VERIFY_DIR/AA-3.exit"
"$CV" watch AA-3 task/AA-3 >/dev/null 2>&1
check "launch failure still writes .exit" "$(cat "$CLOUD_VERIFY_DIR/AA-3.exit" 2>/dev/null)" 98
check "watch records its pid for liveness probes" "$([ -s "$CLOUD_VERIFY_DIR/AA-3.pid" ] && echo yes)" yes

# Terminal verdict path: launch succeeds, first poll is already conclusive.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in ls-remote) exit 0 ;; rev-parse) echo bbb222 ;; *) exit 0 ;; esac
EOF
chmod +x "$BIN/git"
cat > "$BIN/script" <<'EOF'
#!/usr/bin/env bash
echo "Created cloud session: x"; echo "View: .../session_01ABCDEFGH?from=cli"
EOF
chmod +x "$BIN/script"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/claude"
verdict FAIL
make_git "refs/heads/cloud-verify/AA-4/bbb222"
rm -f "$CLOUD_VERIFY_DIR/AA-4.exit"
"$CV" watch AA-4 task/AA-4 >/dev/null 2>&1
# The stub git cannot show the work descends from anything, so acceptance must
# refuse it: an unverifiable verdict never reaches a green or red sentinel.
check "unverifiable cloud work -> .exit=95" "$(cat "$CLOUD_VERIFY_DIR/AA-4.exit" 2>/dev/null)" 95

echo "offload gate:"
# setsid is where the detached watch starts; stubbing it keeps the gate under
# test without a real watch racing the next case.
cat > "$BIN/setsid" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$DIR/setsid.log"
EOF
chmod +x "$BIN/setsid"
# offload pushes the branch and records the base before detaching.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch)     echo "task/${OFFLOAD_TASK}" ;;
  status)     ;;
  merge-base) echo aaa111 ;;
  *)          exit 0 ;;
esac
EOF
chmod +x "$BIN/git"
RESET="$(date -u -d @$((NOW + 4 * 86400)) +%Y-%m-%dT%H:%M:%S+00:00)"   # 3/7 (43%) of the week elapsed
usage() {  # weekly%, session%
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s,"resets_at":"%s"}}' \
    "$2" "$1" "$RESET" > "$DIR/usage.json"
}
export CLOUD_PACE_USAGE_FILE="$DIR/usage.json" CLOUD_PACE_NOW="$NOW"
pace() { python3 "$HERE/cloud-pace.py" 2>/dev/null; }

usage 38 6;  check "38% used at 43% elapsed -> open" "$(pace)" 1
usage 43 6;  check "on pace -> closed"               "$(pace)" 0
usage 60 6;  check "ahead of pace -> closed"         "$(pace)" 0
usage 20 85; check "session ceiling -> closed"       "$(pace)" 0
echo 'not json' > "$DIR/usage.json"
check "unreadable usage fails closed" "$(pace)" 0

rm -f "$DIR/setsid.log"; usage 38 6
ARCHITECT_CLOUD_LANE= "$CV" offload AA-5 task/AA-5 >/dev/null 2>&1; check "flag unset -> 1" "$?" 1
export ARCHITECT_CLOUD_LANE=1
for t in 5 6 7 8 9 10; do
  OFFLOAD_TASK="AA-$t" "$CV" offload "AA-$t" "task/AA-$t" >/dev/null 2>&1 || bad "offload AA-$t" "refused while open"
done
check "open lane has no concurrency bound" "$(wc -l < "$DIR/setsid.log")" 6
usage 60 6
OFFLOAD_TASK=AA-11 "$CV" offload AA-11 task/AA-11 >/dev/null 2>&1; check "ahead of pace -> 1" "$?" 1
check "closed lane detached nothing" "$(wc -l < "$DIR/setsid.log")" 6
usage 38 6
echo "guard suite failed" > "$CLOUD_VERIFY_DIR/AA-12.cloud.rejected"
OFFLOAD_TASK=AA-12 "$CV" offload AA-12 task/AA-12 >/dev/null 2>&1; check "rejected task is not re-offloaded -> 1" "$?" 1
unset ARCHITECT_CLOUD_LANE

echo "acceptance of cloud commits (real git):"
# The trust boundary, so it runs against real repositories rather than stubs.
REALPATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$BIN" | paste -sd:)"
PIXI="$DIR/pixi-bin"; mkdir -p "$PIXI"
printf '#!/usr/bin/env bash\nexit "${PIXI_RC:-0}"\n' > "$PIXI/pixi"; chmod +x "$PIXI/pixi"
R="$DIR/repo"
g() { PATH="$REALPATH" git -C "$R" "$@"; }
commit() {  # path, content, message
  mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" >> "$R/$1"
  g add "$1"; g -c user.name=t -c user.email=t@t commit -qm "$3"
}
# setup <task>: base on main, one task commit touching src/a.rs, launch state.
setup() {
  rm -rf "$R"; PATH="$REALPATH" git init -q -b main "$R"
  commit src/a.rs "fn a() {}" base; commit src/b.rs "fn b() {}" base2
  BASE_SHA="$(g rev-parse HEAD)"
  g checkout -qb "task/$1"; commit src/a.rs "fn a2() {}" task
  LEASE="$(g rev-parse HEAD)"
  printf '%s\n' "$BASE_SHA" > "$CLOUD_VERIFY_DIR/$1.base"
  printf '%s\n' "$LEASE" > "$CLOUD_VERIFY_DIR/$1.cloud.launched-head"
  printf 'refs/heads/cloud-verify/%s/%s\n' "$1" "$LEASE" > "$CLOUD_VERIFY_DIR/$1.cloud.ref"
  printf 'CLOUD-VERIFY-V2\nresult: PASS\nintegration: 0\n' > "$CLOUD_VERIFY_DIR/$1.cloud.verdict"
  rm -f "$CLOUD_VERIFY_DIR/$1.cloud.rejected"
  g checkout -q --detach
}
# publish <task>: top the detached cloud work with an empty verdict commit and
# point the cloud ref at it, then put the worktree back on the task branch.
publish() {
  g -c user.name=t -c user.email=t@t commit -q --allow-empty -m CLOUD-VERIFY-V2
  g update-ref "$(cat "$CLOUD_VERIFY_DIR/$1.cloud.ref")" HEAD
  g checkout -q "task/$1"
}
accept() { ( cd "$R" && PATH="$REALPATH" CLOUD_VERIFY_PIXI_BIN="$PIXI" "$CV" accept "$1" >/dev/null 2>&1 ); }

setup AA-20; commit src/a.rs "fn fixed() {}" fix; commit assets/schemas/x.json "{}" schemas
WORK="$(g rev-parse HEAD)"; publish AA-20
accept AA-20;                                   check "in-scope fix + schemas accepted -> 0" "$?" 0
check "worktree fast-forwarded to cloud work" "$(g rev-parse HEAD)" "$WORK"
check "integration sentinel written" "$(cat "$CLOUD_VERIFY_DIR/AA-20.integration" 2>/dev/null)" 0

setup AA-21; publish AA-21
accept AA-21;                                   check "no cloud commits (clean verify) accepted -> 0" "$?" 0
check "worktree unchanged" "$(g rev-parse HEAD)" "$LEASE"

setup AA-22; commit src/b.rs "fn b2() {}" out-of-scope; publish AA-22
accept AA-22;                                   check "file outside the task -> rejected" "$?" 1
check "rejection recorded" "$([ -f "$CLOUD_VERIFY_DIR/AA-22.cloud.rejected" ] && echo yes)" yes
check "worktree left at launched head" "$(g rev-parse HEAD)" "$LEASE"

setup AA-23; commit src/a.rs "#[allow(dead_code)]" suppress; publish AA-23
accept AA-23;                                   check "added #[allow] -> rejected" "$?" 1

setup AA-24; commit src/a.rs "#[ignore]" ignore; publish AA-24
accept AA-24;                                   check "added #[ignore] -> rejected" "$?" 1

setup AA-25; commit src/a.rs "fn f() {}" fix
printf 'x\n' > "$R/src/a.rs"; g add src/a.rs
g -c user.name=t -c user.email=t@t commit -qm CLOUD-VERIFY-V2
g update-ref "$(cat "$CLOUD_VERIFY_DIR/AA-25.cloud.ref")" HEAD; g checkout -q task/AA-25
accept AA-25;                                   check "verdict commit carrying changes -> rejected" "$?" 1

setup AA-26; g checkout -q --detach "$BASE_SHA"; commit src/a.rs "fn other() {}" unrelated; publish AA-26
accept AA-26;                                   check "work not descending from launch -> rejected" "$?" 1

setup AA-27; g rm -q src/a.rs; g -c user.name=t -c user.email=t@t commit -qm delete; publish AA-27
accept AA-27;                                   check "deleting a file -> rejected" "$?" 1

setup AA-28; commit src/a.rs "fn fixed() {}" fix; publish AA-28
( cd "$R" && PATH="$REALPATH" PIXI_RC=1 CLOUD_VERIFY_PIXI_BIN="$PIXI" "$CV" accept AA-28 >/dev/null 2>&1 )
check "guard suite failing on cloud work -> rejected" "$?" 1
check "worktree reset to launched head" "$(g rev-parse HEAD)" "$LEASE"

setup AA-29; commit src/a.rs "fn fixed() {}" fix; publish AA-29
printf 'dirty\n' >> "$R/src/a.rs"
accept AA-29;                                   check "dirty worktree -> rejected, untouched" "$?" 1
check "uncommitted edit preserved" "$(tail -1 "$R/src/a.rs")" dirty

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
