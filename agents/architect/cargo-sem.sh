#!/usr/bin/env bash
# FIFO N-slot cargo build semaphore (AA-2145 — supersedes the AA-2103 raw-flock
# semaphore and the AA-2014 machine-wide `flock /tmp/cargo-global.lock` mutex).
#
# WHY THIS EXISTS. Concurrent Bevy debug builds must be bounded or they thrash
# the box. AA-2014 bounded ALL Architect cargo at concurrency 1. AA-2103 raised
# it to 2 with two bare `flock` slots — but `flock` grants are NOT FIFO, so under
# many concurrent waiters the oldest one is repeatedly overtaken. That recurred
# as 8.5h (AA-2103) and then 11h+ (AA-2145) starvation of a single waiter while
# newer arrivals sailed past. This script fixes the *fairness* defect and makes
# the concurrency ceiling tunable.
#
# TUNING FOR THE HARDWARE (do not just crank CARGO_SEM_SLOTS). The build box is a
# 4-physical-core / 8-thread 15 W i7-8650U ULV laptop — `nproc` reports 8 but
# that is hyperthreads over 4 cores, and under sustained all-core load the chip
# thermally throttles toward its base clock. Memory is NOT the limit (peak build
# RSS ~2 GB; 24 GB free). CORES are. Each cargo already defaults to
# `--jobs nproc`, so ONE build alone saturates every thread; two already
# oversubscribe the 4 real cores. Piling on more *whole-machine* slots past ~3
# does not add throughput — it adds context-switch churn, cache thrash, and heat
# (=> deeper throttle), and aggregate wall-clock can regress. The effective lever
# is therefore two-dimensional: SLOTS (how many builds run) AND per-build job cap
# (how many threads each build gets). Both defaults are derived from the CPU, not
# hardcoded: SLOTS = physical cores - 1 (reserve one for OS/sccache/orchestration),
# JOBS = logical cores / SLOTS, each floored at 2. On this 4-core/8-thread box
# that is 3 slots x CARGO_BUILD_JOBS=2 ~= 6 threads — more builds in flight than
# the old fixed 2, but far LESS total oversubscription than the old 2 x 8 = 16
# threads. Override either via CARGO_SEM_SLOTS / CARGO_SEM_JOBS; raising SLOTS
# toward the logical-core count on this chip is expected to be slower, not faster
# (measure before trusting a bigger number).
#
# HOW FAIRNESS IS ENFORCED. Admission is a strict ticket queue, decoupled from
# capacity:
#   * ORDER (FIFO): each waiter draws a monotonic ticket T and registers a
#     presence lock `cargo-sem.wait.$T`, both atomically under the ctl-lock. A
#     `serving` low-water mark names the ticket currently allowed to contend for
#     a slot; only the live front (all lower tickets gone) may grab one, and the
#     front advances `serving` past itself only *after* it has secured a slot.
#     So ticket T is admitted strictly before T+1 — zero overtakes.
#   * CAPACITY (<=SLOTS): admission still requires grabbing one of the physical
#     slot locks (`cargo-slot-<i>.lock`), so at most SLOTS builds run at once.
#     The front spins (staying front, blocking no one behind it out of turn)
#     until a slot frees.
#
# WHY IT SELF-HEALS (this is the property AA-2103's raw flock had and a naive
# ticket counter would lose): every lock that gates progress is an flock the
# kernel releases automatically when its owner dies —
#   * a dead *holder* drops its slot lock, freeing capacity;
#   * a dead *waiter* drops its presence lock, so the next `serving` advance
#     probes it, finds it free, and steps over the corpse.
# There is NO explicit "done" counter to leak: a SIGKILL mid-build cannot wedge
# the queue. Do not reintroduce one.
#
# FD LIFETIME (load-bearing — do not "simplify"). The slot lock must be held for
# the ENTIRE lifetime of the wrapped command. We hold it via a fixed numeric fd
# (9) opened with `exec 9>` and run the command as a *child* while that fd stays
# open in this shell. Numeric fds are inherited by children and are NOT
# close-on-exec (unlike bash's auto-allocated {var} fds), so the flock is held
# until the child exits. Do NOT rewrite this to `exec` into the command — that
# drops the lock at exec and reintroduces unbounded concurrency. fd 7 = own
# presence, fd 6 = ctl-lock (both released before the command runs); fd 4 = a
# throwaway liveness probe (subshell-scoped).
#
# We deliberately do NOT `taskset`-pin slots to disjoint core sets (the old 2-slot
# design pinned 0-3 / 4-7). On 4 cores that partitioning both fails to divide
# cleanly for N!=2 and strands cores idle when one build is in a serial link
# phase; `nice -n19` for priority plus the per-build job cap is the better fit.
# Override the state dir with CARGO_SEM_DIR and the poll interval with
# CARGO_SEM_POLL.
#
# Usage: cargo-sem.sh <command> [args...]
set -u

D="${CARGO_SEM_DIR:-/tmp}"
POLL="${CARGO_SEM_POLL:-0.2}"
NPROC="$(nproc 2>/dev/null || echo 4)"
# Physical cores (hyperthreads collapsed) — the real parallelism ceiling. Count
# distinct core ids from lscpu; fall back to nproc where lscpu is unavailable.
PHYS="$(lscpu -p=core 2>/dev/null | grep -v '^#' | sort -u | grep -c '' 2>/dev/null)"
[ "${PHYS:-0}" -ge 1 ] 2>/dev/null || PHYS="$NPROC"
# Default slots: one build per physical core, minus one reserved for the OS,
# sccache, and the Paperclip orchestration that share this box; floor of 2.
# Default per-build job cap: logical cores spread across the slots, floor of 2 so
# a build always makes reasonable progress. Explicit CARGO_SEM_* override either.
SLOTS="${CARGO_SEM_SLOTS:-$(( PHYS - 1 < 2 ? 2 : PHYS - 1 ))}"
JOBS="${CARGO_SEM_JOBS:-$(( NPROC / SLOTS < 2 ? 2 : NPROC / SLOTS ))}"
CTL="$D/cargo-sem.ctl.lock"
NEXT="$D/cargo-sem.next"
SERV="$D/cargo-sem.serving"
WAIT="$D/cargo-sem.wait"

run() { nice -n19 ionice -c3 env CARGO_BUILD_JOBS="$JOBS" "$@"; }

rd() { local v=0; [ -f "$1" ] && v=$(<"$1"); printf '%s' "${v:-0}"; }
wr() { printf '%s' "$2" > "$1"; }

# Is ticket $1 still a live waiter? Non-zero (false) once its owner has released
# the presence lock — by admission or by death. Probe is subshell-scoped so the
# fd (and any momentary acquire) is dropped immediately.
alive() { ! ( exec 4>"$WAIT.$1"; flock -n 4; ) 2>/dev/null; }

# Grab any free physical slot without blocking, holding it on fd 9. Returns 0 and
# leaves fd 9 flocked on success, 1 (fd 9 closed) if every slot is busy.
acquire_slot() {
  local i
  for (( i = 1; i <= SLOTS; i++ )); do
    exec 9>"$D/cargo-slot-$i.lock"
    if flock -n 9; then SLOT_IDX="$i"; return 0; fi
    exec 9>&-
  done
  return 1
}

# --- draw a ticket and register presence atomically under the ctl-lock ---
exec 6>"$CTL"; flock 6
T=$(rd "$NEXT"); wr "$NEXT" $((T + 1))
exec 7>"$WAIT.$T"; flock -n 7   # own presence — self-flock always succeeds
flock -u 6; exec 6>&-

# Optional trace for starvation debugging (AA-2145): records ticket order and,
# on admission, the wait. Off unless CARGO_SEM_DEBUG is set.
DBG="${CARGO_SEM_DEBUG:+$D/cargo-sem.debug.log}"
[ -n "$DBG" ] && printf 'draw ticket=%s t=%s args=%s\n' "$T" "$(date +%s.%N)" "$*" >> "$DBG"

# --- wait for the front of the queue AND a free slot ---
while true; do
  exec 6>"$CTL"; flock 6
  s=$(rd "$SERV")
  while [ "$s" -lt "$T" ] && ! alive "$s"; do rm -f "$WAIT.$s"; s=$((s + 1)); done
  wr "$SERV" "$s"
  flock -u 6; exec 6>&-

  if [ "$s" -lt "$T" ]; then sleep "$POLL"; continue; fi   # a live waiter is ahead

  if acquire_slot; then
    exec 6>"$CTL"; flock 6
    [ "$(rd "$SERV")" = "$T" ] && wr "$SERV" $((T + 1))    # let the next ticket contend
    flock -u 6; exec 6>&-
    exec 7>&-; rm -f "$WAIT.$T"                            # release presence; slot now held
    [ -n "$DBG" ] && printf 'admit ticket=%s slot=%s jobs=%s t=%s\n' "$T" "$SLOT_IDX" "$JOBS" "$(date +%s.%N)" >> "$DBG"
    break
  fi
  sleep "$POLL"                                            # front, but capacity full
done

run "$@"; rc=$?
exec 9>&-
exit "$rc"
