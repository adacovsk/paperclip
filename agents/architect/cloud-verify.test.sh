#!/usr/bin/env bash
# Unit test for cloud-verify.sh's verdict parsing and launch preconditions.
#
# Everything here is stubbed — no cloud session is created, no gist is written,
# no network is touched. What is under test is the part that decides what a
# verdict MEANS, because that is where a wrong answer is expensive: reading
# "the VM never answered" as "the build failed" sends a green branch back to a
# Worker, and reading a stale gist as current lands unverified code.
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
# `gh gist list` emits TSV; column 2 is the description, which is the match key.
make_gh() {
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "gist list")   printf '%s\n' "$1" ;;
  "gist view")   cat "$DIR/body.txt" ;;
esac
EOF
  chmod +x "$BIN/gh"
}
seed_state() {  # task, mark, launched-epoch
  printf '%s\n' "$2" > "$CLOUD_VERIFY_DIR/$1.cloud.mark"
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

MARK="cloud-verify AA-1 bbb222"
NOW="$(date +%s)"

echo "verdict parsing:"
seed_state AA-1 "$MARK" "$NOW"
make_gh "$(printf 'gid1\t%s\t1 file\tsecret\tnow' "$MARK")"

verdict PASS;  "$CV" poll AA-1 >/dev/null 2>&1; check "PASS  -> 0"  "$?" 0
verdict FAIL;  "$CV" poll AA-1 >/dev/null 2>&1; check "FAIL  -> 1"  "$?" 1
verdict STALE; "$CV" poll AA-1 >/dev/null 2>&1; check "STALE -> 98" "$?" 98
# A truncated or malformed body must never read as green.
printf 'CLOUD-VERIFY-V1\ntask: AA-1\n' > "$DIR/body.txt"
"$CV" poll AA-1 >/dev/null 2>&1;               check "garbage -> 99" "$?" 99

echo "timing:"
verdict PASS
make_gh ""                                      # no gist published yet
seed_state AA-1 "$MARK" "$NOW"
"$CV" poll AA-1 >/dev/null 2>&1;               check "pending inside deadline -> 75" "$?" 75
seed_state AA-1 "$MARK" "$((NOW - 99999))"
"$CV" poll AA-1 >/dev/null 2>&1;               check "past deadline -> 99"           "$?" 99

echo "staleness:"
# A verdict for the SAME task at a DIFFERENT head must not be matched. This is
# the case that would otherwise land unverified code: the branch was pushed
# again after the cloud session started.
seed_state AA-1 "cloud-verify AA-1 ccc333" "$NOW"
make_gh "$(printf 'gid1\t%s\t1 file\tsecret\tnow' "$MARK")"
"$CV" poll AA-1 >/dev/null 2>&1;               check "different head not matched -> 75" "$?" 75
# Substring collision: AA-1 must not pick up AA-12's verdict.
seed_state AA-1 "$MARK" "$NOW"
make_gh "$(printf 'gid9\tcloud-verify AA-12 bbb222\t1 file\tsecret\tnow' )"
"$CV" poll AA-1 >/dev/null 2>&1;               check "AA-12 not matched by AA-1 -> 75" "$?" 75

echo "launch preconditions:"
"$CV" poll AA-404 >/dev/null 2>&1;             check "poll before launch -> 96" "$?" 96
make_gh ""
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
make_gh ""
rm -f "$CLOUD_VERIFY_DIR/AA-3.exit"
"$CV" watch AA-3 task/AA-3 >/dev/null 2>&1
check "launch failure still writes .exit" "$(cat "$CLOUD_VERIFY_DIR/AA-3.exit" 2>/dev/null)" 98

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
make_gh "$(printf 'gid1\tcloud-verify AA-4 bbb222\t1 file\tsecret\tnow')"
rm -f "$CLOUD_VERIFY_DIR/AA-4.exit"
"$CV" watch AA-4 task/AA-4 >/dev/null 2>&1
check "red verdict lands as .exit=1" "$(cat "$CLOUD_VERIFY_DIR/AA-4.exit" 2>/dev/null)" 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
