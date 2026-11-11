#!/usr/bin/env bash
# Decision tests for verify-sem.sh.  Run: bash agents/architect/verify-sem.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SEM="$HERE/verify-sem.sh"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
sem() { VERIFY_SEM_DIR="$D/sem" VERIFY_SEM_HELD="" "$@"; }

if ! command -v flock >/dev/null 2>&1; then
  echo "skip - no flock on this box; verify-sem.sh runs unbounded here"
  exit 0
fi

# --- a free slot is taken and the command runs holding it --------------------
out="$(sem env VERIFY_SEM_SLOTS=1 "$SEM" bash -c 'echo "held=$VERIFY_SEM_HELD"' 2>&1)"
check "the command runs with the slot marked held" "$out" "held=1"

sem env VERIFY_SEM_SLOTS=1 "$SEM" bash -c 'exit 7' 2>/dev/null
check "the command's exit status is the wrapper's" "$?" "7"

# --- every slot held: the command waits, then runs when one frees -------------
mkdir -p "$D/sem"
( exec 9>"$D/sem/slot-1.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.5
sem env VERIFY_SEM_SLOTS=1 "$SEM" bash -c 'date +%s > "$0"' "$D/ran" 2> "$D/waiter.err" &
waiter=$!
sleep 1.5
if [ -e "$D/ran" ]; then fail "the command ran while the only slot was held"; else ok "the command waits while the only slot is held"; fi
wait "$holder" "$waiter"
if [ -e "$D/ran" ]; then ok "the command runs once the slot frees"; else fail "the command never ran after the slot freed"; fi
if grep -q "waiting for a slot" "$D/waiter.err" && grep -q "got a slot after" "$D/waiter.err"; then
  ok "the wait is announced and its length reported"
else
  fail "the wait was silent: $(cat "$D/waiter.err")"
fi

# --- a second slot is used past a held first one ------------------------------
( exec 9>"$D/sem/slot-1.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.5
sem env VERIFY_SEM_SLOTS=2 "$SEM" true 2> "$D/two.err"
check "a free second slot is taken without waiting" "$(grep -c waiting "$D/two.err")" "0"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# --- a caller already holding a slot does not queue for another ---------------
( exec 9>"$D/sem/slot-1.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.5
out="$(VERIFY_SEM_DIR="$D/sem" VERIFY_SEM_HELD=1 VERIFY_SEM_SLOTS=1 timeout 2 "$SEM" echo ran 2>&1)"
check "a holder's child runs at once" "$out" "ran"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# --- zero slots disables the wait and takes no lock ---------------------------
rm -rf "$D/sem"
out="$(sem env VERIFY_SEM_SLOTS=0 "$SEM" echo ran 2>&1)"
check "zero slots runs the command" "$out" "ran"
if [ -e "$D/sem" ]; then fail "zero slots still created the lock directory"; else ok "zero slots takes no lock"; fi

"$SEM" 2>/dev/null
check "no command is a usage error" "$?" "2"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
