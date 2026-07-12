#!/usr/bin/env bash
# Load test for the FIFO cargo semaphore (AA-2145). Verifies, under a synthetic
# burst of concurrent dispatches, that (1) at most 2 wrapped commands ever run at
# once, and (2) waiters are admitted in strict ticket (arrival) order — the
# oldest waiter is never overtaken.
#
# FIFO is checked against the semaphore's own ticket numbers (via CARGO_SEM_DEBUG),
# NOT the dispatch index: with many processes racing for the ctl-lock, dispatch
# order and ticket-assignment order can differ, and the semaphore only promises
# to honor the ticket order it actually assigned. Run:
#   bash agents/architect/cargo-sem.test.sh [num_waiters]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SEM="$HERE/cargo-sem.sh"
DIR="$(mktemp -d)"
LOG="$DIR/events.log"; : > "$LOG"

export CARGO_SEM_DIR="$DIR"
export CARGO_SEM_POLL="0.05"
export CARGO_SEM_DEBUG="1"

WAITERS="${1:-6}"   # > 2 slots, so most must queue
HOLD="1.0"          # each "build" occupies its slot this long (>> dispatch stagger)

cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

work() {
  ( flock 200; printf 'START pid=%s t=%s\n' "$BASHPID" "$(date +%s.%N)" >> "$LOG"; ) 200>"$DIR/log.lock"
  sleep "$HOLD"
  ( flock 200; printf 'END   pid=%s t=%s\n' "$BASHPID" "$(date +%s.%N)" >> "$LOG"; ) 200>"$DIR/log.lock"
}
export -f work
export DIR LOG HOLD

echo "Dispatching $WAITERS waiters at 2-slot semaphore ($SEM)..."
pids=()
for i in $(seq 1 "$WAITERS"); do
  "$SEM" bash -c 'work' _ &
  pids+=($!)
  sleep 0.25   # >> ticket-draw time, so contention is real but tickets still interleave under load
done
for p in "${pids[@]}"; do wait "$p"; done

echo "--- debug log (ticket draws + admissions) ---"; cat "$DIR/cargo-sem.debug.log"
echo "--- event log (START/END) ---"; cat "$LOG"

python3 - "$LOG" "$DIR/cargo-sem.debug.log" "$WAITERS" <<'PY'
import sys, re
evlog, dbglog, waiters = sys.argv[1], sys.argv[2], int(sys.argv[3])

# (1) capacity: max simultaneous START..END overlap <= 2
evts = []
for line in open(evlog):
    m = re.match(r'(START|END)\s+pid=\d+ t=([\d.]+)', line)
    if m: evts.append((float(m[2]), +1 if m[1] == 'START' else -1))
cur = peak = 0
for _, d in sorted(evts):
    cur += d; peak = max(peak, cur)
print(f"peak concurrency = {peak} (limit 2)")

# (2) FIFO: admissions ordered by time must have ascending ticket numbers
admits = []
for line in open(dbglog):
    m = re.match(r'admit ticket=(\d+) slot=\d+ t=([\d.]+)', line)
    if m: admits.append((float(m[2]), int(m[1])))
order = [tk for _t, tk in sorted(admits)]
print(f"admission order by ticket = {order}")

fail = 0
if peak > 2:
    print("FAIL: concurrency exceeded 2"); fail = 1
if order != sorted(order):
    bad = sum(1 for i in range(len(order)) for j in range(i) if order[j] > order[i])
    print(f"FAIL: ticket admission not strictly FIFO ({bad} overtakes)"); fail = 1
else:
    print("strict FIFO: no ticket overtaken")
if len(order) != waiters:
    print(f"FAIL: {len(order)}/{waiters} waiters admitted"); fail = 1

print("RESULT:", "PASS" if not fail else "FAIL")
sys.exit(fail)
PY
