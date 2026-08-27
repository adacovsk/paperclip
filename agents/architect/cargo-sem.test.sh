#!/usr/bin/env bash
# Load test for the FIFO cargo semaphore (AA-2145). Verifies, under a synthetic
# burst of concurrent dispatches, that (1) at most SLOTS wrapped commands ever run
# at once, and (2) waiters are admitted in strict ticket (arrival) order — the
# oldest waiter is never overtaken.
#
# FIFO is checked against the semaphore's own ticket numbers (via CARGO_SEM_DEBUG),
# NOT the dispatch index: with many processes racing for the ctl-lock, dispatch
# order and ticket-assignment order can differ, and the semaphore only promises
# to honor the ticket order it actually assigned. Run:
#   bash agents/architect/cargo-sem.test.sh [num_waiters] [slots]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SEM="$HERE/cargo-sem.sh"
DIR="$(mktemp -d)"
LOG="$DIR/events.log"; : > "$LOG"

WAITERS="${1:-6}"   # > slots, so most must queue
SLOTS="${2:-2}"     # capacity under test
HOLD="1.0"          # each "build" occupies its slot this long (>> dispatch stagger)

export CARGO_SEM_DIR="$DIR"
export CARGO_SEM_POLL="0.05"
export CARGO_SEM_DEBUG="1"
export CARGO_SEM_SLOTS="$SLOTS"

cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

work() {
  ( flock 200; printf 'START pid=%s t=%s\n' "$BASHPID" "$(date +%s.%N)" >> "$LOG"; ) 200>"$DIR/log.lock"
  sleep "$HOLD"
  ( flock 200; printf 'END   pid=%s t=%s\n' "$BASHPID" "$(date +%s.%N)" >> "$LOG"; ) 200>"$DIR/log.lock"
}
export -f work
export DIR LOG HOLD

echo "Dispatching $WAITERS waiters at $SLOTS-slot semaphore ($SEM)..."
# Each waiter runs in its OWN directory, because that is what the fleet does:
# one worktree per task. The per-worktree mutex serializes same-directory
# builds, so dispatching every waiter from a shared cwd would measure that
# mutex instead of the semaphore and report a peak concurrency of 1.
pids=()
for i in $(seq 1 "$WAITERS"); do
  mkdir -p "$DIR/wt$i"
  ( cd "$DIR/wt$i" && "$SEM" bash -c 'work' _ ) &
  pids+=($!)
  sleep 0.25   # >> ticket-draw time, so contention is real but tickets still interleave under load
done
for p in "${pids[@]}"; do wait "$p"; done

echo "--- debug log (ticket draws + admissions) ---"; cat "$DIR/cargo-sem.debug.log"
echo "--- event log (START/END) ---"; cat "$LOG"

python3 - "$LOG" "$DIR/cargo-sem.debug.log" "$WAITERS" "$SLOTS" <<'PY'
import sys, re
evlog, dbglog, waiters, slots = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

# (1) capacity: max simultaneous START..END overlap <= slots
evts = []
for line in open(evlog):
    m = re.match(r'(START|END)\s+pid=\d+ t=([\d.]+)', line)
    if m: evts.append((float(m[2]), +1 if m[1] == 'START' else -1))
cur = peak = 0
for _, d in sorted(evts):
    cur += d; peak = max(peak, cur)
print(f"peak concurrency = {peak} (limit {slots})")

# (2) FIFO: admissions ordered by time must have ascending ticket numbers
# Match only the two fields this assertion needs (ticket, t) and tolerate any
# others in between. An earlier version pinned the exact sequence
# `ticket=.. slot=.. jobs=.. t=..`; adding `cgu=` to the trace then matched
# nothing, and the suite reported "0/N waiters admitted" — a parser failure
# wearing a fairness failure's clothes. Keep this loose so trace fields stay
# additive. (`\st=` cannot mis-fire on `ticket=`: that has no `=` after its `t`.)
admits = []
for line in open(dbglog):
    m = re.match(r'admit ticket=(\d+)\b.*\st=([\d.]+)', line)
    if m: admits.append((float(m[2]), int(m[1])))
order = [tk for _t, tk in sorted(admits)]
print(f"admission order by ticket = {order}")

fail = 0
if peak > slots:
    print(f"FAIL: concurrency exceeded {slots}"); fail = 1
elif peak < min(slots, waiters):
    print(f"WARN: peak {peak} < expected {min(slots, waiters)} (slots may be under-utilized)")
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
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# --- per-worktree mutex: same directory must never build concurrently ---
# Two cargo runs in one worktree serialize on cargo's own target/ lock anyway;
# the defect this guards is them serializing *after* admission, each holding a
# slot while only one progresses. Both must overlap zero times, and — the part
# that matters — the waiter must not be occupying a slot while it waits.
echo
echo "Checking per-worktree serialization (2 waiters, same cwd, $SLOTS slots)..."
: > "$LOG"
mkdir -p "$DIR/shared"
for _ in 1 2; do ( cd "$DIR/shared" && "$SEM" bash -c 'work' _ ) & done
wait

python3 - "$LOG" <<'PY'
import sys, re
evts = []
for line in open(sys.argv[1]):
    m = re.match(r'(START|END)\s+pid=\d+ t=([\d.]+)', line)
    if m: evts.append((float(m[2]), +1 if m[1] == 'START' else -1))
cur = peak = 0
for _, d in sorted(evts):
    cur += d; peak = max(peak, cur)
starts = sum(1 for _t, d in evts if d == +1)
print(f"same-worktree peak concurrency = {peak} (must be 1), completed = {starts}/2")
ok = peak == 1 and starts == 2
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY

# --- the memory ceiling widening while a build is queued (AA-5045) ---
# SLOTS is derived from a *rolling* window of recent build RSS, so it moves. The
# defect was resolving it once at launch: a waiter kept contending against its
# launch-time ceiling, and as FIFO head it held the low-water mark against
# everyone behind it, so the queue stopped rather than merely running slow.
#
# Drives the real input rather than a fake: no CARGO_SEM_SLOTS here (that is an
# explicit decision and would bypass the memgate entirely), just the peak-RSS
# file the derivation reads. Start it wide enough that only one build fits, then
# shrink the recorded peak while the second waits. A waiter that re-derives is
# admitted immediately; one that does not waits for the first to finish.
echo
echo "Checking that a queued waiter picks up a widened memory ceiling..."
MEMDIR="$(mktemp -d)"
: > "$MEMDIR/events.log"
MEMKB=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
# One "build" claims 70% of RAM, so (MemTotal * 70/100) / peak == 1 slot.
printf '%s\n' "$(( MEMKB * 70 / 100 ))" > "$MEMDIR/cargo-sem.peak-rss"

(
  export CARGO_SEM_DIR="$MEMDIR" CARGO_SEM_POLL="0.05"
  unset CARGO_SEM_SLOTS
  export DIR="$MEMDIR" LOG="$MEMDIR/events.log" HOLD="6"
  mkdir -p "$MEMDIR/a" "$MEMDIR/b"
  ( cd "$MEMDIR/a" && "$SEM" bash -c 'work' _ ) &
  sleep 1
  ( cd "$MEMDIR/b" && "$SEM" bash -c 'work' _ ) &
  # Second is now queued behind a 1-slot ceiling. Widen it: a cheap recent build
  # drops the window's peak, so the derivation now fits several.
  sleep 1
  printf '%s\n' "$(( MEMKB / 1000 ))" > "$MEMDIR/cargo-sem.peak-rss"
  wait
)

python3 - "$MEMDIR/events.log" <<'PY'
import sys, re
starts = []
for line in open(sys.argv[1]):
    m = re.match(r'(START|END)\s+pid=\d+ t=([\d.]+)', line)
    if m and m[1] == 'START':
        starts.append(float(m[2]))
starts.sort()
ok = len(starts) == 2 and (starts[1] - starts[0]) < 5.0
gap = f"{starts[1] - starts[0]:.2f}s" if len(starts) == 2 else "n/a"
print(f"second admission came {gap} after the first (must be < 5s; the first build holds 6s)")
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
rm -rf "$MEMDIR"
