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
verdict SUPERSEDED; "$CV" poll AA-1 >/dev/null 2>&1; check "SUPERSEDED -> 94" "$?" 94
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
  rev-parse)  echo ccc333 ;;
  push)       printf '%s\n' "$*" >> "$PUSH_LOG" ;;
  *)          exit 0 ;;
esac
EOF
chmod +x "$BIN/git"
export PUSH_LOG="$DIR/push.log"
RESET="$(date -u -d @$((NOW + 4 * 86400)) +%Y-%m-%dT%H:%M:%S+00:00)"   # 3/7 (43%) of the week elapsed
usage() {  # weekly%, session%
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s,"resets_at":"%s"}}' \
    "$2" "$1" "$RESET" > "$DIR/usage.json"
}
export CLOUD_PACE_USAGE_FILE="$DIR/usage.json" CLOUD_PACE_NOW="$NOW"
pace() { python3 "$HERE/cloud-pace.py" 2>/dev/null; }

# By default only the ceilings close the lane; pace is not compared.
usage 60 6;  check "ahead of pace -> open"             "$(pace)" 1
usage 20 85; check "session ceiling -> closed"         "$(pace)" 0
usage 90 6;  check "week ceiling -> closed"            "$(pace)" 0
# CLOUD_PACE_ENFORCE_PACE=1 restores the pacing gate, under the same session ceiling.
usage 38 6;  check "enforced: 38% used at 43% elapsed -> open" "$(CLOUD_PACE_ENFORCE_PACE=1 pace)" 1
usage 43 6;  check "enforced: on pace -> closed"       "$(CLOUD_PACE_ENFORCE_PACE=1 pace)" 0
usage 60 6;  check "enforced: ahead of pace -> closed" "$(CLOUD_PACE_ENFORCE_PACE=1 pace)" 0
usage 20 85; check "enforced: session ceiling -> closed" "$(CLOUD_PACE_ENFORCE_PACE=1 pace)" 0
usage 60 6;  check "enforce is exactly 1"              "$(CLOUD_PACE_ENFORCE_PACE=true pace)" 1
echo 'not json' > "$DIR/usage.json"
check "unreadable usage fails closed" "$(pace)" 0
check "unreadable usage fails closed when enforced" "$(CLOUD_PACE_ENFORCE_PACE=1 pace)" 0

# The cache: only the network path uses it, so drive that path with a file:// URL.
(
  unset CLOUD_PACE_USAGE_FILE
  export CLOUD_PACE_URL="file://$DIR/remote.json" CLOUD_PACE_CACHE="$DIR/usage-cache.json"
  export CLOUD_PACE_CREDENTIALS="$DIR/creds.json"
  echo '{"claudeAiOauth":{"accessToken":"t"}}' > "$CLOUD_PACE_CREDENTIALS"
  usage 38 6; cp "$DIR/usage.json" "$DIR/remote.json"
  check "a fresh read opens and is cached" "$(pace)" 1
  check "the reading was cached"           "$([ -f "$CLOUD_PACE_CACHE" ] && echo yes)" yes
  usage 60 6; cp "$DIR/usage.json" "$DIR/remote.json"
  check "inside the TTL the cache answers, not the meter" "$(pace)" 1
  rm -f "$DIR/remote.json"; touch -d '-10 minutes' "$CLOUD_PACE_CACHE"
  check "a failed read falls back to a recent cache" "$(pace)" 1
  touch -d '-20 minutes' "$CLOUD_PACE_CACHE"
  check "a failed read with a stale cache fails closed" "$(pace)" 0
  echo "$PASS $FAIL" > "$DIR/cache.counts"
)
read -r PASS FAIL < "$DIR/cache.counts"

rm -f "$DIR/setsid.log"; usage 38 6
ARCHITECT_CLOUD_LANE= "$CV" offload AA-5 task/AA-5 >/dev/null 2>&1; check "flag unset -> 1" "$?" 1
export ARCHITECT_CLOUD_LANE=1
for t in 5 6 7 8 9 10; do
  OFFLOAD_TASK="AA-$t" "$CV" offload "AA-$t" "task/AA-$t" >/dev/null 2>&1 || bad "offload AA-$t" "refused while open"
done
# detach backgrounds the watcher (through systemd-run where the box has it), so
# the last one can still be starting when the loop ends.
for _ in $(seq 50); do [ "$(wc -l < "$DIR/setsid.log")" -ge 6 ] && break; sleep 0.1; done
check "open lane has no concurrency bound" "$(wc -l < "$DIR/setsid.log")" 6
# A pre-push hook outlives the Architect's run and strands the launch.
check "offload pushes each task"             "$(wc -l < "$PUSH_LOG")" 6
check "offload push skips the pre-push hook" "$(grep -vc -- '--no-verify' "$PUSH_LOG")" 0
usage 92 6
OFFLOAD_TASK=AA-11 "$CV" offload AA-11 task/AA-11 >/dev/null 2>&1; check "week ceiling -> 1" "$?" 1
usage 60 6
CLOUD_PACE_ENFORCE_PACE=1 OFFLOAD_TASK=AA-11 "$CV" offload AA-11 task/AA-11 >/dev/null 2>&1; check "enforced, ahead of pace -> 1" "$?" 1
check "closed lane detached nothing" "$(wc -l < "$DIR/setsid.log")" 6
usage 38 6
echo "guard suite failed" > "$CLOUD_VERIFY_DIR/AA-12.cloud.rejected"
OFFLOAD_TASK=AA-12 "$CV" offload AA-12 task/AA-12 >/dev/null 2>&1; check "rejection with no recorded head is not re-offloaded -> 1" "$?" 1

echo "a rejection earns one informed retry at the same head:"
reject_at() { echo "$2" > "$CLOUD_VERIFY_DIR/$1.cloud.rejected"; echo "$3" > "$CLOUD_VERIFY_DIR/$1.cloud.rejected-head"; }
reject_at AA-13 "guard suite failed" ccc333
OFFLOAD_TASK=AA-13 "$CV" offload AA-13 task/AA-13 >/dev/null 2>&1; check "first rejection at this head -> re-offloaded" "$?" 0
check "the retry carries the reason" "$(cat "$CLOUD_VERIFY_DIR/AA-13.cloud.prior-rejection" 2>/dev/null)" "guard suite failed"
reject_at AA-13 "cloud commits delete files" ccc333
OFFLOAD_TASK=AA-13 "$CV" offload AA-13 task/AA-13 >/dev/null 2>&1; check "second rejection at the same head -> 1" "$?" 1
reject_at AA-14 "guard suite failed" ccc333; echo ccc333 > "$CLOUD_VERIFY_DIR/AA-14.cloud.retried-head"
echo "old reason" > "$CLOUD_VERIFY_DIR/AA-14.cloud.prior-rejection"
reject_at AA-14 "guard suite failed" ddd444
OFFLOAD_TASK=AA-14 "$CV" offload AA-14 task/AA-14 >/dev/null 2>&1; check "rejection at an older head -> offloaded" "$?" 0
check "a new head forgets the old reason" "$([ -f "$CLOUD_VERIFY_DIR/AA-14.cloud.prior-rejection" ] && echo stale || echo clean)" clean

echo "offload records the verify mode for the detached watcher:"
OFFLOAD_TASK=AA-15 CLOUD_VERIFY_RESOLVE=1 "$CV" offload AA-15 task/AA-15 >/dev/null 2>&1
check "CLOUD_VERIFY_RESOLVE=1 -> resolve mark" "$([ -f "$CLOUD_VERIFY_DIR/AA-15.cloud.resolve" ] && echo yes)" yes
OFFLOAD_TASK=AA-15 CLOUD_VERIFY_WIDE=1 "$CV" offload AA-15 task/AA-15 >/dev/null 2>&1
check "a later offload without it clears the mark" "$([ -f "$CLOUD_VERIFY_DIR/AA-15.cloud.resolve" ] && echo kept || echo cleared)" cleared
check "CLOUD_VERIFY_WIDE=1 -> wide mark" "$([ -f "$CLOUD_VERIFY_DIR/AA-15.cloud.wide" ] && echo yes)" yes
unset ARCHITECT_CLOUD_LANE

echo "launch prompt follows the mode:"
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in ls-remote) exit 0 ;; rev-parse) echo bbb222 ;; *) exit 0 ;; esac
EOF
chmod +x "$BIN/git"
cat > "$BIN/script" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" > "$DIR/launch.cmd"
echo "View: .../session_01ABCDEFGH?from=cli"
EOF
chmod +x "$BIN/script"
launched() { "$CV" launch "$1" "task/$1" >/dev/null 2>&1; cat "$DIR/launch.cmd"; }
rm -f "$CLOUD_VERIFY_DIR"/AA-16.cloud.*
P="$(launched AA-16)"
check "plain verify forbids rebasing"      "$(printf '%s' "$P" | grep -c 'Do NOT rebase or merge')" 1
check "plain verify runs at low effort"    "$(printf '%s' "$P" | grep -c -- '--effort low')" 1
: > "$CLOUD_VERIFY_DIR/AA-16.cloud.resolve"
P="$(launched AA-16)"
check "resolve verify rebases onto main"   "$(printf '%s' "$P" | grep -c 'CONFLICTS WITH CURRENT main')" 1
check "resolve verify reports rebased-onto" "$(printf '%s' "$P" | grep -c 'rebased-onto:')" 1
check "resolve verify runs at high effort" "$(printf '%s' "$P" | grep -c -- '--effort high')" 1
rm -f "$CLOUD_VERIFY_DIR/AA-16.cloud.resolve"; : > "$CLOUD_VERIFY_DIR/AA-16.cloud.wide"
echo "guard suite failed" > "$CLOUD_VERIFY_DIR/AA-16.cloud.prior-rejection"
P="$(launched AA-16)"
check "wide verify widens scope"           "$(printf '%s' "$P" | grep -c 'WIDE SCOPE')" 1
check "a retry is told why"                "$(printf '%s' "$P" | grep -c 'for this reason: guard suite failed')" 1
rm -f "$CLOUD_VERIFY_DIR"/AA-16.cloud.*

echo "completion wake:"
# The wake must name the Verify task; unnamed, the server binds it to a stale one.
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DIR/curl.log"
EOF
chmod +x "$BIN/curl"
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "ls-remote" ] && exit 2
exit 0
EOF
chmod +x "$BIN/git"
rm -f "$DIR/curl.log"
PAPERCLIP_API_URL=http://x PAPERCLIP_AGENT_ID=a "$CV" watch AA-30 task/AA-30 AA-31 >/dev/null 2>&1
check "wake names the verify task" "$(grep -c '"issueIdentifier":"AA-31"' "$DIR/curl.log" 2>/dev/null)" 1
rm -f "$DIR/curl.log"
PAPERCLIP_API_URL=http://x PAPERCLIP_AGENT_ID=a "$CV" watch AA-32 task/AA-32 >/dev/null 2>&1
check "wake falls back to the task id" "$(grep -c '"issueIdentifier":"AA-32"' "$DIR/curl.log" 2>/dev/null)" 1
rm -f "$BIN/curl"

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
# setup <task> [task-line]: base on main, one task commit appending task-line
# (default `fn a2() {}`) to src/a.rs, launch state. src/b.rs is outside every
# task: a match over the enum in a.rs, long enough that two edits far apart in
# it are separate hunks.
B_RS='fn b() {}
fn kind(k: Kind) -> u8 {
    match k {
        Kind::Old => 1,
    }
}
// one
// two
// three
// four
// five
// six
// seven
// eight
fn tail() {}'
setup() {
  rm -rf "$R"; PATH="$REALPATH" git init -q -b main "$R"
  commit src/a.rs "fn a() {}" base; commit src/b.rs "$B_RS" base2
  BASE_SHA="$(g rev-parse HEAD)"
  g checkout -qb "task/$1"; commit src/a.rs "${2:-fn a2() {\}}" task
  LEASE="$(g rev-parse HEAD)"
  printf '%s\n' "$BASE_SHA" > "$CLOUD_VERIFY_DIR/$1.base"
  printf '%s\n' "$LEASE" > "$CLOUD_VERIFY_DIR/$1.cloud.launched-head"
  printf 'refs/heads/cloud-verify/%s/%s\n' "$1" "$LEASE" > "$CLOUD_VERIFY_DIR/$1.cloud.ref"
  printf 'CLOUD-VERIFY-V2\nresult: PASS\n' > "$CLOUD_VERIFY_DIR/$1.cloud.verdict"
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
why() { grep -c -- "$2" "$CLOUD_VERIFY_DIR/$1.cloud.rejected" 2>/dev/null; }
accept() { ( cd "$R" && PATH="$REALPATH" CLOUD_VERIFY_PIXI_BIN="$PIXI" "$CV" accept "$1" >/dev/null 2>&1 ); }

setup AA-20; commit src/a.rs "fn fixed() {}" fix; commit assets/schemas/x.json "{}" schemas
WORK="$(g rev-parse HEAD)"; publish AA-20
accept AA-20;                                   check "in-scope fix + schemas accepted -> 0" "$?" 0
check "worktree fast-forwarded to cloud work" "$(g rev-parse HEAD)" "$WORK"

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
accept AA-29;                                   check "uncommitted edit to a file the cloud changed -> rejected" "$?" 1
check "uncommitted edit preserved" "$(tail -1 "$R/src/a.rs")" dirty

# A pre-push guard rewriting an unrelated tracked file must not block the work.
setup AA-33; commit src/a.rs "fn fixed() {}" fix; WORK="$(g rev-parse HEAD)"; publish AA-33
printf 'reseeded\n' >> "$R/src/b.rs"
accept AA-33;                                   check "unrelated uncommitted edit -> accepted" "$?" 0
check "worktree fast-forwarded past unrelated dirt" "$(g rev-parse HEAD)" "$WORK"
check "unrelated edit preserved" "$(tail -1 "$R/src/b.rs")" reseeded

setup AA-34; commit src/a.rs "fn fixed() {}" fix; publish AA-34
printf 'reseeded\n' >> "$R/src/b.rs"
( cd "$R" && PATH="$REALPATH" PIXI_RC=1 CLOUD_VERIFY_PIXI_BIN="$PIXI" "$CV" accept AA-34 >/dev/null 2>&1 )
check "guard failure with unrelated dirt -> rejected" "$?" 1
check "rollback keeps unrelated edit" "$(tail -1 "$R/src/b.rs")" reseeded
check "rollback returns to launched head" "$(g rev-parse HEAD)" "$LEASE"

echo "out-of-scope fixes the task's own diff caused:"
# The task adds a variant; the exhaustive match in src/b.rs, outside the task,
# stops compiling. Each case edits b.rs and declares (or fails to) in the verdict.
declare_oos() { printf 'out-of-scope: %s\n' "$2" >> "$CLOUD_VERIFY_DIR/$1.cloud.verdict"; }
sed_commit() {  # path, sed expression, message
  sed -i "$2" "$R/$1"; g add "$1"; g -c user.name=t -c user.email=t@t commit -qm "$3"
}
ADD_ARM='/Kind::Old => 1,/a\        Kind::Added => 2,'

setup AA-40 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm
WORK="$(g rev-parse HEAD)"; publish AA-40
declare_oos AA-40 "src/b.rs E0004 Added -- non-exhaustive patterns: \`Kind::Added\` not covered"
accept AA-40;                                   check "declared diff-caused match arm -> accepted" "$?" 0
check "worktree fast-forwarded to the out-of-scope fix" "$(g rev-parse HEAD)" "$WORK"

setup AA-41 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm; publish AA-41
accept AA-41;                                   check "undeclared out-of-scope edit -> rejected" "$?" 1
check "worktree left at launched head" "$(g rev-parse HEAD)" "$LEASE"

# A call site rewritten to a signature the task changed removes a line.
setup AA-42 "fn kind(k: Kind, n: u8) -> u8 { 0 }"
sed_commit src/b.rs 's/^fn kind(k: Kind) -> u8 {$/fn kind(k: Kind, n: u8) -> u8 {/' callsite; publish AA-42
declare_oos AA-42 "src/b.rs E0061 kind -- this function takes 2 arguments but 1 argument was supplied"
accept AA-42;                                   check "declared rewrite at a changed signature -> accepted" "$?" 0

setup AA-43 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm; publish AA-43
declare_oos AA-43 "src/b.rs E0004 Unrelated -- non-exhaustive patterns"
accept AA-43;                                   check "identifier not in the task's diff -> rejected" "$?" 1

setup AA-44 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm; publish AA-44
declare_oos AA-44 "src/b.rs E0277 Added -- the trait bound is not satisfied"
accept AA-44;                                   check "non-qualifying error code -> rejected" "$?" 1

setup AA-45 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm
sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' sneak; publish AA-45
declare_oos AA-45 "src/b.rs E0004 Added -- non-exhaustive patterns"
accept AA-45;                                   check "a hunk not at a use of the identifier -> rejected" "$?" 1

setup AA-46 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm
sed_commit src/b.rs '/^\/\/ one$/,/^\/\/ four$/d' prune; publish AA-46
declare_oos AA-46 "src/b.rs E0004 Added -- non-exhaustive patterns"
accept AA-46;                                   check "out-of-scope hunk removing 4 lines -> rejected" "$?" 1

setup AA-47 "    Added,"; commit src/c.rs "fn c(k: Kind) { if let Kind::Added = k {} }" new; publish AA-47
declare_oos AA-47 "src/c.rs E0004 Added -- non-exhaustive patterns"
accept AA-47;                                   check "new out-of-scope file -> rejected" "$?" 1

setup AA-48 "fn a2() {}"; sed_commit src/b.rs '/Kind::Old => 1,/a\        fn x() {}' kw; publish AA-48
declare_oos AA-48 "src/b.rs E0004 fn -- non-exhaustive patterns"
accept AA-48;                                   check "keyword as the identifier -> rejected" "$?" 1

setup AA-49 "    Added,"; sed_commit src/b.rs "$ADD_ARM" arm; commit README "x" docs; publish AA-49
declare_oos AA-49 "src/b.rs E0004 Added -- non-exhaustive patterns"
declare_oos AA-49 "README E0004 Added -- non-exhaustive patterns"
accept AA-49;                                   check "non-Rust out-of-scope file -> rejected" "$?" 1

echo "main-repair tasks: base breakage outside the task is in scope:"
repair() { : > "$CLOUD_VERIFY_DIR/$1.cloud.main-repair"; }

# The same edit AA-45 rejects (a hunk unrelated to the task's diff) is the job
# when the task restores main.
setup AA-60 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' basefix
WORK="$(g rev-parse HEAD)"; publish AA-60; repair AA-60
declare_oos AA-60 "src/b.rs too_many_arguments tail -- this function has too many arguments"
accept AA-60;                                   check "main-repair: declared base fix -> accepted" "$?" 0
check "main-repair: worktree fast-forwarded" "$(g rev-parse HEAD)" "$WORK"

setup AA-61 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' basefix; publish AA-61; repair AA-61
accept AA-61;                                   check "main-repair: undeclared edit -> rejected" "$?" 1

setup AA-62 "    Added,"; commit src/c.rs "fn c() {}" new; publish AA-62; repair AA-62
declare_oos AA-62 "src/c.rs E0425 c -- cannot find function"
accept AA-62;                                   check "main-repair: new file -> rejected" "$?" 1

setup AA-63 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/#[allow(clippy::all)]\nfn tail() {}/' sup; publish AA-63; repair AA-63
declare_oos AA-63 "src/b.rs too_many_arguments tail -- this function has too many arguments"
accept AA-63;                                   check "main-repair: suppression -> rejected" "$?" 1

setup AA-64 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' basefix; publish AA-64
declare_oos AA-64 "src/b.rs too_many_arguments tail -- this function has too many arguments"
accept AA-64;                                   check "same edit without the main-repair mark -> rejected" "$?" 1

echo "wide scope: a red outside the task's files, re-verified:"
setup AA-65 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' testfix
WORK="$(g rev-parse HEAD)"; publish AA-65; : > "$CLOUD_VERIFY_DIR/AA-65.cloud.wide"
declare_oos AA-65 "src/b.rs systems::tests::tail_counts tail -- assertion failed"
accept AA-65;                                   check "wide: declared fix outside the task -> accepted" "$?" 0
setup AA-66 "    Added,"; sed_commit src/b.rs 's/^fn tail() {}$/fn tail() { unrelated() }/' testfix
publish AA-66; : > "$CLOUD_VERIFY_DIR/AA-66.cloud.wide"
accept AA-66;                                   check "wide: undeclared edit -> rejected" "$?" 1
rm -f "$CLOUD_VERIFY_DIR"/AA-6[56].cloud.wide

echo "resolve mode: the VM rebases a conflicting branch onto main:"
# setup_resolve <task> [task-line]: as setup, plus a bare origin holding main
# and the task branch, then a main commit that conflicts with the task's edit to
# src/a.rs. Leaves the worktree on the task branch at the launched head and HEAD
# detached for the VM's work to start from origin/main.
O="$DIR/origin.git"
setup_resolve() {
  setup "$1" "${2:-fn a2() {\}}"; g checkout -q "task/$1"
  rm -rf "$O"; PATH="$REALPATH" git init -q --bare "$O"
  g remote add origin "$O"; g push -q origin main "task/$1"
  g checkout -q main; commit src/a.rs "fn main_moved() {}" main-moves; g push -q origin main
  ONTO="$(g rev-parse HEAD)"; g fetch -q origin
  : > "$CLOUD_VERIFY_DIR/$1.cloud.resolve"
  printf 'rebased-onto: %s\n' "$ONTO" >> "$CLOUD_VERIFY_DIR/$1.cloud.verdict"
  g checkout -q --detach "$ONTO"
}
resolved() {  # the VM's resolution: main's line and the task's line both kept
  commit src/a.rs "${1:-fn a2() {\}}" "task, resolved onto main"
}

setup_resolve AA-80; resolved; WORK="$(g rev-parse HEAD)"; publish AA-80
accept AA-80;                                   check "resolved onto origin/main -> accepted" "$?" 0
check "worktree moved to the resolved work"     "$(g rev-parse HEAD)" "$WORK"
check "resolved branch published to origin"     "$(g ls-remote origin refs/heads/task/AA-80 | cut -f1)" "$WORK"
check "landing's base is the commit it was rebased onto" "$(cat "$CLOUD_VERIFY_DIR/AA-80.base")" "$ONTO"

setup_resolve AA-81; resolved; publish AA-81
sed -i '/^rebased-onto:/d' "$CLOUD_VERIFY_DIR/AA-81.cloud.verdict"
accept AA-81;                                   check "no rebased-onto -> rejected" "$?" 1
check "  ...for that reason (AA-81)" "$(why AA-81 'no rebased-onto')" 1

setup_resolve AA-82; g checkout -q --detach "$ONTO"; commit src/a.rs "fn off_main() {}" side
SIDE="$(g rev-parse HEAD)"; resolved; publish AA-82
sed -i "s/^rebased-onto: .*/rebased-onto: $SIDE/" "$CLOUD_VERIFY_DIR/AA-82.cloud.verdict"
accept AA-82;                                   check "rebased-onto not on origin/main -> rejected" "$?" 1
check "  ...for that reason (AA-82)" "$(why AA-82 'is not on origin/main')" 1
check "worktree left at launched head"          "$(g rev-parse HEAD)" "$LEASE"

setup_resolve AA-83; resolved; commit src/b.rs "fn widened() {}" widen; publish AA-83
accept AA-83;                                   check "resolution into a file the task never touched -> rejected" "$?" 1
check "  ...for that reason (AA-83)" "$(why AA-83 'outside the task')" 1

setup_resolve AA-84 "#[allow(dead_code)] fn a2() {}"; resolved "#[allow(dead_code)] fn a2() {}"; publish AA-84
accept AA-84;                                   check "the task's own suppression is not charged to the VM -> accepted" "$?" 0

setup_resolve AA-85; resolved; commit src/a.rs "#[allow(unused)]" sup; publish AA-85
accept AA-85;                                   check "a suppression the VM added -> rejected" "$?" 1
check "  ...for that reason (AA-85)" "$(why AA-85 'suppression')" 1

setup_resolve AA-86; resolved; publish AA-86
g push -q origin "$(g rev-parse main):refs/heads/task/AA-86" -f
accept AA-86;                                   check "task branch moved on origin since launch -> rejected" "$?" 1
check "  ...for that reason (AA-86)" "$(why AA-86 'moved on origin')" 1
check "worktree returned to launched head"      "$(g rev-parse HEAD)" "$LEASE"

setup_resolve AA-87; resolved; publish AA-87; rm -f "$CLOUD_VERIFY_DIR/AA-87.cloud.resolve"
accept AA-87;                                   check "rebased work without the resolve mark -> rejected" "$?" 1
check "  ...for that reason (AA-87)" "$(why AA-87 'do not descend from the launched head')" 1
rm -f "$CLOUD_VERIFY_DIR"/AA-8?.cloud.resolve

echo "superseded: main already does the task's work:"
# The VM publishes no commits, only a verdict naming the main commit. A claim
# that closes a task is checked here, not trusted.
supersede() {  # task, sha: a commit-less SUPERSEDED verdict naming sha
  g checkout -q --detach "$LEASE"; publish "$1"
  printf 'CLOUD-VERIFY-V2\nresult: SUPERSEDED\nsuperseded-by: %s\n--- errors ---\nsrc/a.rs:2 already does it\n' "$2" \
    > "$CLOUD_VERIFY_DIR/$1.cloud.verdict"
  rm -f "$CLOUD_VERIFY_DIR/$1.superseded"
}
superseded() { ( cd "$R" && PATH="$REALPATH" "$CV" accept-superseded "$1" >/dev/null 2>&1 ); }

setup_resolve AA-90; supersede AA-90 "$ONTO"
superseded AA-90;                               check "main commit touching the task's file -> accepted" "$?" 0
check "  ...marker names the commit"            "$(grep -c "^superseded-by: $ONTO" "$CLOUD_VERIFY_DIR/AA-90.superseded")" 1
check "  ...marker names the overlap"           "$(grep -c '^overlap: src/a.rs$' "$CLOUD_VERIFY_DIR/AA-90.superseded")" 1
check "  ...marker carries the VM's citation"   "$(grep -c '^src/a.rs:2 already does it$' "$CLOUD_VERIFY_DIR/AA-90.superseded")" 1
check "  ...worktree untouched"                 "$(g rev-parse HEAD)" "$LEASE"

setup_resolve AA-91; g checkout -q main; commit src/b.rs "fn elsewhere() {}" disjoint; g push -q origin main
DISJOINT="$(g rev-parse HEAD)"; supersede AA-91 "$DISJOINT"
superseded AA-91;                               check "main commit over a disjoint file set -> rejected" "$?" 1
check "  ...for that reason (AA-91)" "$(why AA-91 "changes none of the task's files")" 1
check "  ...no marker written"                  "$([ -f "$CLOUD_VERIFY_DIR/AA-91.superseded" ] && echo yes || echo no)" no

setup_resolve AA-92; resolved; publish AA-92
printf 'CLOUD-VERIFY-V2\nresult: SUPERSEDED\nsuperseded-by: %s\n' "$ONTO" > "$CLOUD_VERIFY_DIR/AA-92.cloud.verdict"
superseded AA-92;                               check "superseded verdict carrying commits -> rejected" "$?" 1
check "  ...for that reason (AA-92)" "$(why AA-92 'must carry no commits')" 1

setup_resolve AA-93; g checkout -q --detach "$ONTO"; commit src/a.rs "fn off_main() {}" side
SIDE="$(g rev-parse HEAD)"; supersede AA-93 "$SIDE"
superseded AA-93;                               check "superseded-by not on origin/main -> rejected" "$?" 1
check "  ...for that reason (AA-93)" "$(why AA-93 'is not on origin/main')" 1

setup_resolve AA-94; supersede AA-94 ""
sed -i '/^superseded-by:/d' "$CLOUD_VERIFY_DIR/AA-94.cloud.verdict"
superseded AA-94;                               check "no superseded-by line -> rejected" "$?" 1
rm -f "$CLOUD_VERIFY_DIR"/AA-9?.cloud.resolve

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
