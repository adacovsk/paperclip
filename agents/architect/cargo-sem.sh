#!/usr/bin/env bash
# FIFO 2-slot cargo build semaphore (AA-2145 — supersedes the AA-2103 raw-flock
# semaphore and the AA-2014 machine-wide `flock /tmp/cargo-global.lock` mutex).
#
# WHY THIS EXISTS. Two Bevy debug builds fit the box (8 cores / 31 GB); a third
# must wait. AA-2014 bounded ALL Architect cargo at concurrency 1. AA-2103 raised
# the ceiling to 2 with two bare `flock` slots — but `flock` grants are NOT FIFO,
# so under many concurrent waiters the oldest one is repeatedly overtaken. That
# recurred as 8.5h (AA-2103) and then 11h+ (AA-2145) starvation of a single
# waiter while newer arrivals sailed past. This script fixes the *fairness*
# defect while keeping the concurrency ceiling at 2.
#
# HOW FAIRNESS IS ENFORCED. Admission is a strict ticket queue, decoupled from
# capacity:
#   * ORDER (FIFO): each waiter draws a monotonic ticket T and registers a
#     presence lock `cargo-sem.wait.$T`, both atomically under the ctl-lock. A
#     `serving` low-water mark names the ticket currently allowed to contend for
#     a slot; only the live front (all lower tickets gone) may grab one, and the
#     front advances `serving` past itself only *after* it has secured a slot.
#     So ticket T is admitted strictly before T+1 — zero overtakes.
#   * CAPACITY (<=2): admission still requires grabbing one of two physical slot
#     locks (`cargo-slot-1.lock` / `cargo-slot-2.lock`), so at most two builds
#     ever run at once. The front spins (staying front, blocking no one behind it
#     out of turn) until a slot frees.
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
# (9 or 8) opened with `exec N>` and run the command as a *child* while that fd
# stays open in this shell. Numeric fds are inherited by children and are NOT
# close-on-exec (unlike bash's auto-allocated {var} fds), so the flock is held
# until the child exits. Do NOT rewrite this to `exec` into the command — that
# drops the lock at exec and reintroduces unbounded concurrency. fd 7 = own
# presence, fd 6 = ctl-lock (both released before the command runs); fd 4 = a
# throwaway liveness probe (subshell-scoped).
#
# Each slot pins a disjoint core set (0-3 / 4-7) so two concurrent builds don't
# fight over the same cores. Override the state directory with CARGO_SEM_DIR
# (tests use this) and the poll interval with CARGO_SEM_POLL.
#
# Usage: cargo-sem.sh <command> [args...]
set -u

D="${CARGO_SEM_DIR:-/tmp}"
POLL="${CARGO_SEM_POLL:-0.2}"
CTL="$D/cargo-sem.ctl.lock"
NEXT="$D/cargo-sem.next"
SERV="$D/cargo-sem.serving"
WAIT="$D/cargo-sem.wait"

run() { nice -n19 ionice -c3 taskset -c "$1" "${@:2}"; }

rd() { local v=0; [ -f "$1" ] && v=$(<"$1"); printf '%s' "${v:-0}"; }
wr() { printf '%s' "$2" > "$1"; }

# Is ticket $1 still a live waiter? Non-zero (false) once its owner has released
# the presence lock — by admission or by death. Probe is subshell-scoped so the
# fd (and any momentary acquire) is dropped immediately.
alive() { ! ( exec 4>"$WAIT.$1"; flock -n 4; ) 2>/dev/null; }

# Grab a physical slot without blocking. Sets SLOT (held fd) and CORES on success.
acquire_slot() {
  exec 9>"$D/cargo-slot-1.lock"
  if flock -n 9; then SLOT=9; CORES="0-3"; return 0; fi
  exec 9>&-
  exec 8>"$D/cargo-slot-2.lock"
  if flock -n 8; then SLOT=8; CORES="4-7"; return 0; fi
  exec 8>&-
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
    [ -n "$DBG" ] && printf 'admit ticket=%s slot=%s t=%s\n' "$T" "$SLOT" "$(date +%s.%N)" >> "$DBG"
    break
  fi
  sleep "$POLL"                                            # front, but capacity full
done

run "$CORES" "$@"; rc=$?
eval "exec $SLOT>&-"
exit "$rc"
