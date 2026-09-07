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
echo "Checking that the slot ceiling ignores recorded peak RSS..."
# The cap is (MemTotal x MEMPCT) / MEM_PER_BUILD — two declared numbers. The
# $RSSF window is evidence for choosing MEM_PER_BUILD, never an input, so its
# contents must not move SLOTS.
#
# Measured by OBSERVED CONCURRENCY, not by arithmetic on the debug line. An
# earlier version of this check inferred SLOTS as THREADS/(jobs x cgu), which
# silently became 8/(2x16)=0 once CGU stopped being part of the thread product —
# and then passed on 0 == 0. Counting how many builds actually run at once
# cannot go vacuous that way.
peak_conc_for_window() {
  local dir; dir="$(mktemp -d)"
  printf '%s\n' "$1" > "$dir/cargo-sem.peak-rss"
  : > "$dir/events.log"
  ( export CARGO_SEM_DIR="$dir" CARGO_SEM_POLL="0.05" DIR="$dir" LOG="$dir/events.log" HOLD="3"
    unset CARGO_SEM_SLOTS
    mkdir -p "$dir/w1" "$dir/w2" "$dir/w3" "$dir/w4"
    for w in w1 w2 w3 w4; do ( cd "$dir/$w" && "$SEM" bash -c 'work' _ ) & done
    wait ) >/dev/null 2>&1
  python3 - "$dir/events.log" <<'EOF'
import sys, re
ev = []
for line in open(sys.argv[1]):
    m = re.match(r'(START|END)\s+pid=\d+ t=([\d.]+)', line)
    if m: ev.append((float(m[2]), 1 if m[1] == 'START' else -1))
ev.sort()
cur = peak = 0
for _, d in ev:
    cur += d; peak = max(peak, cur)
print(peak)
EOF
  rm -rf "$dir"
}

MEMKB=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
small=$(peak_conc_for_window "$(( MEMKB / 1000 ))")
huge=$(peak_conc_for_window "$(( MEMKB * 70 / 100 ))")
echo "peak concurrency with a cheap-build window = $small; with a RAM-sized outlier = $huge (must match, and be >= 1)"
if [ "$small" = "$huge" ] && [ "${small:-0}" -ge 1 ] 2>/dev/null; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "Checking that CGU stays at or above CGU_FLOOR..."
# CGU is declared (16) and is NOT part of the SLOTS x JOBS thread product.
# CARGO_SEM_CGU_DIV makes a heavy stage proportionally lighter, but must not
# drive CGU into the range the benchmark rejects: measured on this crate,
# CGU=1 cost 123 min / 11.5 GiB against CGU=16 at 67 min / 7.2 GiB, and the
# test stage's CGU_DIV=2 is what produced the 1-2 unit builds.
cgu_for() {
  local dir; dir="$(mktemp -d)"
  ( export CARGO_SEM_DIR="$dir" CARGO_SEM_DEBUG=1; unset CARGO_SEM_SLOTS
    [ -n "${1:-}" ] && export CARGO_SEM_CGU_DIV="$1"
    "$SEM" true ) >/dev/null 2>&1
  local line; line=$(grep -o 'cgu=[0-9]*' "$dir/cargo-sem.debug.log" 2>/dev/null | head -1)
  rm -rf "$dir"
  echo "${line#cgu=}"
}
base=$(cgu_for ""); div2=$(cgu_for 2); div99=$(cgu_for 99)
floor="${CARGO_SEM_CGU_FLOOR:-8}"
echo "CGU base=$base  CGU_DIV=2 -> $div2  CGU_DIV=99 -> $div99  (floor $floor)"
if [ "${base:-0}" -ge "$floor" ] 2>/dev/null \
   && [ "${div2:-0}" -ge "$floor" ] 2>/dev/null \
   && [ "${div99:-0}" -ge "$floor" ] 2>/dev/null; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "Checking that a chain's next stage outranks waiters that have not started (AA-3129)..."
# The defect: each stage of a verify is a separate call, so releasing the slot
# sent the chain to the BACK and half-finished work lost to work that had not
# started. With one slot, a two-stage chain, and two competitors arriving while
# stage 1 builds, the fix is visible as the admission SEQUENCE: the chain's
# second stage must be admitted before either competitor.
chain_seq() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/chain" "$dir/b" "$dir/c"
  ( export CARGO_SEM_DIR="$dir" CARGO_SEM_DEBUG=1 CARGO_SEM_SLOTS=1 \
           CARGO_SEM_POLL=0.05 CARGO_SEM_RESUME="$1"
    ( cd "$dir/chain" && "$SEM" sleep 1 && "$SEM" sleep 0.2 ) &
    sleep 0.3; ( cd "$dir/b" && "$SEM" sleep 0.2 ) &   # both arrive while stage 1
    sleep 0.1; ( cd "$dir/c" && "$SEM" sleep 0.2 ) &   # still holds the only slot
    wait ) >/dev/null 2>&1
  grep -oE '^admit(-resume)?' "$dir/cargo-sem.debug.log" 2>/dev/null | tr '\n' ' '
  rm -rf "$dir"
}
on="$(chain_seq 1)"; off="$(chain_seq 0)"
echo "resume lane on : $on"
echo "resume lane off: $off"
# On: stage 2 is second. Off: nothing uses the lane and stage 2 is last.
if [ "$on" = "admit admit-resume admit admit " ] && [ "$off" = "admit admit admit admit " ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "Checking that the resume lane is bounded by hops and by the marker's grace..."
# A lane that always wins starves the one below it, so a chain may use it only
# CARGO_SEM_RESUME_MAX times; and a marker older than the grace window means the
# chain ended, so the next cargo from that worktree is a new arrival.
hop_seq() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/wt"
  ( export CARGO_SEM_DIR="$dir" CARGO_SEM_DEBUG=1 CARGO_SEM_SLOTS=1 \
           CARGO_SEM_POLL=0.05 CARGO_SEM_RESUME_MAX="$1" CARGO_SEM_RESUME_GRACE="$2"
    cd "$dir/wt"
    "$SEM" true && { [ -n "$3" ] && sleep "$3"; "$SEM" true; } \
                && { [ -n "$3" ] && sleep "$3"; "$SEM" true; } ) >/dev/null 2>&1
  grep -c '^admit-resume' "$dir/cargo-sem.debug.log" 2>/dev/null || true
  rm -rf "$dir"
}
capped="$(hop_seq 1 30 '')"      # 3 stages, 1 hop allowed  -> exactly 1 resume
uncapped="$(hop_seq 4 30 '')"    # 3 stages, 4 hops allowed -> 2 resumes
expired="$(hop_seq 4 1 1.5)"     # marker lapses between stages -> 0 resumes
echo "hops capped at 1 -> $capped resume admissions (want 1)"
echo "hops capped at 4 -> $uncapped resume admissions (want 2)"
echo "marker expired   -> $expired resume admissions (want 0)"
if [ "$capped" = "1" ] && [ "$uncapped" = "2" ] && [ "$expired" = "0" ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
