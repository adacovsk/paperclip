#!/usr/bin/env bash
# Regression test for the in-place-edit hazard (AA-4983).
#
# bash reads a script incrementally, remembering a byte OFFSET into the open
# file. Rewriting the file while an instance is running makes that instance
# resume at its old offset inside the NEW bytes — executing garbage, or dying on
# a syntax error in a file that is itself syntactically clean. cargo-sem.sh
# defends against this by re-execing from an unlinked private snapshot.
#
# Run: bash agents/architect/cargo-sem-pin.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SEM="$HERE/cargo-sem.sh"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# --- 1. The mechanism exists (control) -------------------------------------
# A script with no snapshot guard, rewritten mid-run with a length change, is
# corrupted. If this stops failing, bash changed and the guard may be moot —
# investigate rather than deleting the guard.
write_victim() { # $1=dest $2=pad
  {
    printf '%s\n' "$2"
    echo 'sleep 1'
    echo 'echo TAIL-RAN'
  } > "$1"
}
write_victim "$D/victim.sh" "# p"
bash "$D/victim.sh" > "$D/victim.log" 2>&1 &
vpid=$!
sleep 0.3
write_victim "$D/victim.sh" "# $(printf 'pad%.0s' {1..30})"
wait "$vpid" 2>/dev/null
if grep -qE 'command not found|syntax error|unexpected' "$D/victim.log"; then
  ok "control: an unguarded script is corrupted by an in-place rewrite"
else
  fail "control did not reproduce the hazard — bash behaviour may have changed"
  echo "      victim.log:"; sed 's/^/      /' "$D/victim.log"
fi

# --- 2. cargo-sem.sh re-execs from a snapshot ------------------------------
# The re-exec block must be the FIRST executable statement: anything above it is
# still read from the mutable file.
first_stmt="$(grep -nvE '^[[:space:]]*(#|$)' "$SEM" | head -1)"
case "$first_stmt" in
  *'if [ -z "${CARGO_SEM_PINNED:-}" ]; then'*) ok "the snapshot guard is the first executable statement" ;;
  *) fail "first executable statement is not the snapshot guard: $first_stmt" ;;
esac

# --- 3. The snapshot is unlinked while in use ------------------------------
# An unlinked file still reads correctly through the open fd, and cleans itself
# up even on SIGKILL. Assert both: the child's $0 is not the repo path, and the
# path it is running from no longer exists on disk.
export CARGO_SEM_DIR="$D" CARGO_SEM_POLL=0.05 CARGO_SEM_SLOTS=1
probe="$(bash "$SEM" bash -c 'printf "%s|%s" "$CARGO_SEM_PINNED" "$(test -e "$CARGO_SEM_PINNED" && echo present || echo unlinked)"' 2>/dev/null | tail -1)"
snap_path="${probe%%|*}"
snap_state="${probe##*|}"
if [ -n "$snap_path" ] && [ "$snap_path" != "$SEM" ]; then
  ok "the wrapped command runs from a snapshot, not from $SEM"
else
  fail "no snapshot path was exported (got: '$probe')"
fi
[ "$snap_state" = "unlinked" ] \
  && ok "the snapshot is unlinked while still executing" \
  || fail "the snapshot is still on disk and can itself be rewritten (state: '$snap_state')"

# --- 4. The real thing survives an in-place rewrite ------------------------
# Copy the semaphore, run a wrapper that holds its slot, rewrite the copy
# underneath it with a length change, and require a clean exit and no garbage.
cp "$SEM" "$D/sem.sh"
bash "$D/sem.sh" sleep 4 > "$D/sem.log" 2>&1 &
spid=$!
sleep 1.5
{ echo "# a leading comment that shifts every byte offset below it"; echo "# and another"; cat "$SEM"; } > "$D/sem.new"
cat "$D/sem.new" > "$D/sem.sh"   # in place: same inode, new bytes
wait "$spid"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qE 'command not found|syntax error|unexpected' "$D/sem.log"; then
  ok "a live wrapper survives an in-place rewrite of its own script"
else
  fail "wrapper did not survive the rewrite (exit $rc)"
  sed 's/^/      /' "$D/sem.log"
fi

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
