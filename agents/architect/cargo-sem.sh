#!/usr/bin/env bash
# FIFO N-slot cargo build semaphore. Supersedes an earlier raw-flock slot pair
# and, before that, a machine-wide `flock /tmp/cargo-global.lock` mutex.
#
# WHY THIS EXISTS. Concurrent Bevy debug builds must be bounded or they thrash
# the box. The mutex bounded ALL Architect cargo at concurrency 1. The next revision raised
# it to 2 with two bare `flock` slots — but `flock` grants are NOT FIFO, so under
# many concurrent waiters the oldest one is repeatedly overtaken. That recurred
# as 8.5h and then 11h+ starvation of a single waiter while
# newer arrivals sailed past. This script fixes the *fairness* defect and makes
# the concurrency ceiling tunable.
#
# TUNING FOR THE HARDWARE (do not just crank CARGO_SEM_SLOTS). The build box is a
# 4-physical-core / 8-thread 15 W i7-8650U ULV laptop — `nproc` reports 8 but
# that is hyperthreads over 4 cores, and under sustained all-core load the chip
# thermally throttles toward its base clock. CORES are the primary limit. Each
# cargo already defaults to `--jobs nproc`, so ONE build alone saturates every
# thread; two already oversubscribe the 4 real cores. Piling on more
# *whole-machine* slots past ~3 does not add throughput — it adds context-switch
# churn, cache thrash, and heat (=> deeper throttle), and aggregate wall-clock
# can regress. The effective lever is THREE-dimensional: SLOTS (how many builds
# run) x JOBS (how many rustc each build spawns) x CGU (how many codegen threads
# live inside each rustc).
#
# MEMORY IS A SECOND CEILING, and it binds sooner than SLOTS suggests. An earlier
# revision of this header claimed "peak build RSS ~2 GB; 24 GB free" and
# concluded memory was a non-issue. That is stale by ~4x: measured with 3 slots
# held, the two workspace-crate rustc alone were 7.8 GB (`--crate-name
# rust_bevy_rpg src/main.rs`, 47 min in) and 4.1 GB (`src/lib.rs`) — 12 GB live,
# 642 MB free of 31 GB, and into swap. The big linking rustc for this crate is
# the outlier, not the dependency rustc (~0.2-0.3 GB each), so worst case scales
# with SLOTS: 3 slots x ~8 GB is ~24 GB on a 31 GB box that also holds ~12 GB of
# page cache. Do NOT raise SLOTS on the assumption that only cores are scarce —
# swapping a build box is worse than serializing it. CGU also moves this: fewer
# codegen units means fewer LLVM modules live at once, so dropping CGU relieves
# memory pressure as well as thread pressure.
#
# The third dimension is the one that bites, because CARGO_BUILD_JOBS does not
# reach it. A job cap bounds how many rustc processes cargo starts; it says
# nothing about the threads *inside* one. With codegen-units > 1 and opt-level
# > 0 rustc runs local ThinLTO across its codegen units, one thread per unit,
# and cargo's default unit count is 256 incremental / 16 non-incremental. Since
# every command here runs CARGO_INCREMENTAL=0, that is 16 threads per rustc.
#
# An earlier revision of this header claimed "3 slots x CARGO_BUILD_JOBS=2 ~= 6
# threads". That was wrong by 6x: measured on this box, 3 admitted builds ran 4
# rustc totalling 37 threads (14/7/12/4) at load 17-25 on 4 physical cores,
# which is what made the desktop unusable. SLOTS x JOBS was never the whole
# product — SLOTS x JOBS x CGU is.
#
# All three defaults derive from the CPU, none are hardcoded:
#   SLOTS = physical cores - 1  (reserve one for OS/sccache/orchestration)
#   JOBS  = logical cores / SLOTS
#   CGU   = physical cores      (a 4x cut from cargo's 16; floor of 1)
# each floored as noted. On this 4-core/8-thread box: 3 slots x 2 jobs x 4 units.
# MEMORY IS ALSO A DERIVED CEILING, not just a warning in this header. SLOTS is
# additionally capped by MemTotal divided by the worst build RSS this box has
# actually recorded (run() measures every build with /usr/bin/time and keeps a
# monotonic high-water mark). Nothing here is a guessed constant: an unmeasured
# machine keeps the CPU-derived slots, and the cap only ever *lowers* them. That
# is what makes these settings portable to a box with the same cores and a third
# of the RAM, which the CPU-only derivation above would happily thrash.
#
# Override via CARGO_SEM_SLOTS / CARGO_SEM_JOBS / CARGO_SEM_CGU; raising SLOTS
# toward the logical-core count on this chip is expected to be slower, not faster
# (measure before trusting a bigger number). If the box still thrashes, CGU is
# the cheapest lever to drop next (2, then 1) — it costs single-build codegen
# parallelism, which concurrent slots already supply at the machine level.
#
# CGU is exported as CARGO_PROFILE_DEV_CODEGEN_UNITS rather than committed to
# bevy-rpg's Cargo.toml on purpose. It must NOT apply to a human's dev build:
# workspace crates compile incrementally at 256 units, and lowering that
# coarsens rebuilds and slows the edit-compile-run loop. Fleet builds are
# non-incremental, so they lose nothing. (Dependencies are a different case and
# are capped in bevy-rpg's [profile.dev.package."*"] — cargo never builds them
# incrementally, so the cap is free for everyone.)
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
# WHY IT SELF-HEALS (this is the property the raw flock had and a naive
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
# a build always makes reasonable progress. Default codegen units: one per
# physical core, floor of 1 (1 is legal — it serializes codegen within a rustc,
# it does not disable it). Explicit CARGO_SEM_* overrides any of the three.
SLOTS="${CARGO_SEM_SLOTS:-$(( PHYS - 1 < 2 ? 2 : PHYS - 1 ))}"
JOBS="${CARGO_SEM_JOBS:-$(( NPROC / SLOTS < 2 ? 2 : NPROC / SLOTS ))}"
CGU="${CARGO_SEM_CGU:-$(( PHYS < 1 ? 1 : PHYS ))}"
# Stage-relative cut. CARGO_SEM_CGU_DIV divides whatever CGU resolved to above,
# floored at 1, so a caller can say "this stage is the heavy one, give it less"
# without embedding a number tuned to one machine. The test stage passes 2 (see
# the Architect INSTRUCTIONS launch block): on this 4-core box that is 4 -> 2,
# and on a 16-core box 16 -> 8 — the same *proportional* relief rather than a
# crippling absolute. Divides an explicit CARGO_SEM_CGU too, so "half whatever
# this box decided" holds however CGU was arrived at.
CGU=$(( CGU / ${CARGO_SEM_CGU_DIV:-1} ))
[ "$CGU" -ge 1 ] || CGU=1

# MEMORY CEILING — derived from measurement, never from a constant.
#
# Every default above comes from core counts, but the header is explicit that
# memory binds first ("3 slots x ~8 GB is ~24 GB on a 31 GB box"). A box with
# these 4 cores and 8 GB would thrash on settings that are fine here; one with
# 128 GB would never OOM at all. So slots are additionally capped by what this
# machine can actually hold.
#
# The per-build figure is NOT hardcoded: `run()` records peak RSS of each build
# via /usr/bin/time and keeps a monotonic high-water mark in $RSSF, so the
# estimate is this box's own worst observed build. Until a build has been
# measured the cap is simply inactive — an unmeasured machine keeps the
# CPU-derived slots rather than accepting an invented number.
#
# MemTotal, not MemAvailable: every caller must agree on capacity or they would
# disagree about how many slot locks exist. MemTotal is stable; MemAvailable
# moves as builds start, so deriving from it would let two concurrent callers
# compute different SLOTS. The mark only ever rises, so the cap only ever
# *lowers* slots — capacity shrinks, never grows, which is the safe direction
# (a slot already held above the new ceiling drains and is simply not reused).
#
# An explicit CARGO_SEM_SLOTS still wins: if the operator has said how many,
# that is a decision, not an estimate.
RSSF="$D/cargo-sem.peak-rss"
RSSL="$D/cargo-sem.rss.lock"
if [ -z "${CARGO_SEM_SLOTS:-}" ]; then
  _memkb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
  _peak=$(cat "$RSSF" 2>/dev/null | tr -dc '0-9'); _peak="${_peak:-0}"
  if [ "${_memkb:-0}" -gt 0 ] && [ "$_peak" -gt 0 ] 2>/dev/null; then
    _memslots=$(( _memkb / _peak ))
    [ "$_memslots" -ge 1 ] || _memslots=1
    [ "$_memslots" -lt "$SLOTS" ] && SLOTS="$_memslots"
  fi
fi
CTL="$D/cargo-sem.ctl.lock"
NEXT="$D/cargo-sem.next"
SERV="$D/cargo-sem.serving"
WAIT="$D/cargo-sem.wait"

# --- ONE cargo per acquisition (guard runs before any lock is touched) ---
# A slot is held for the whole lifetime of the wrapped command, so wrapping a
# `a && b && c` chain in a single call holds one slot for the whole chain. That
# is not a fairness bug — the ticket queue below is strictly FIFO — it is a HOLD
# DURATION bug, and it is what actually starves the queue: measured, a single
# `clippy && test --lib && test --test ...` acquisition held a slot 3-7 hours
# while the front waiter sat 9h50m. Chains are why 8.5h and then 11h+
# starvations recurred *after* fairness was fixed; the queue drains only if slots
# turn over. Call this script once per cargo invocation instead:
#
#     cargo-sem.sh env CARGO_INCREMENTAL=0 cargo clippy
#     cargo-sem.sh env CARGO_INCREMENTAL=0 cargo test --lib
#
# Each waits its own turn, so a long verify yields the slot between steps. This
# is a hard error, not a warning: it costs seconds now, versus hours of a wedged
# queue. Escape hatch CARGO_SEM_ALLOW_CHAIN=1 if a genuine single-slot chain is
# ever needed. The regex counts `cargo` only as a command word — `/tmp/cargo-x`,
# `~/.cargo/bin`, and `CARGO_INCREMENTAL=0` do not match.
if [ "${CARGO_SEM_ALLOW_CHAIN:-0}" != "1" ]; then
  _ncargo=$(printf '%s' "$*" | grep -oE '(^|[;&|[:space:]])cargo[[:space:]]' | grep -c '' || true)
  if [ "${_ncargo:-0}" -gt 1 ]; then
    printf 'cargo-sem.sh: refusing a %s-cargo chain in one slot acquisition.\n' "$_ncargo" >&2
    printf '  Hold time, not fairness, is what starves this queue: one slot would be\n' >&2
    printf '  held for the whole chain (measured: 3-7h holds, 9h50m front-of-queue wait).\n' >&2
    printf '  Split it — invoke this script once per cargo command:\n' >&2
    printf '      cargo-sem.sh env CARGO_INCREMENTAL=0 cargo clippy\n' >&2
    printf '      cargo-sem.sh env CARGO_INCREMENTAL=0 cargo test --lib\n' >&2
    printf '  Override with CARGO_SEM_ALLOW_CHAIN=1 only if you truly need one slot.\n' >&2
    printf '  Got: %s\n' "$*" >&2
    exit 64
  fi
fi

# --- sccache must already be up BEFORE we hold a lock ---
# If a cargo cold-starts the sccache server from *under* a slot lock, the
# daemon inherits fd 9 and never exits — and flock releases only when every fd
# on the open file description closes, so that slot is lost for the life of the
# daemon. Capacity silently drops by one, permanently.
#
# ~/.profile pre-starts the server for exactly this reason, but that only fires
# for *login* shells, and agent runs deliberately avoid `bash -lc` (see
# architect/INSTRUCTIONS.md — ~/.profile unconditionally exports PAPERCLIP_*,
# which would clobber adapter-injected env). Worse, sccache self-exits after its
# idle timeout (default 600s) and this pipeline is idle most of the day, so the
# daemon reliably dies overnight and the next morning's first build is the one
# that cold-starts it — under a slot. The guarantee therefore has to live here,
# at the point of use, outside every flock. Idempotent; no-op if already up.
command -v sccache >/dev/null 2>&1 && sccache --start-server >/dev/null 2>&1 || true

# CARGO_PROFILE_DEV_CODEGEN_UNITS bounds the codegen threads inside each rustc —
# the dimension CARGO_BUILD_JOBS cannot see (see header). Env, not config, so it
# scopes to fleet builds only and never reaches a human's incremental dev loop.
#
# It also records what the build actually cost in memory. `/usr/bin/time -f %M`
# reports peak RSS of the largest single child, which is exactly the figure that
# matters here: the outlier linking rustc, not the ~0.2-0.3 GB dependency ones.
# The value feeds the memory slot cap above as a monotonic high-water mark, so
# the ceiling is derived from this machine's own builds rather than a constant
# guessed for one box. Strictly best-effort: no `/usr/bin/time`, no measurement,
# and the cap simply stays off. Never allowed to affect the build's exit status.
run() {
  local rss="$D/.rss.$$" rc=0
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -f '%M' -o "$rss" \
      nice -n19 ionice -c3 env \
      CARGO_BUILD_JOBS="$JOBS" \
      CARGO_PROFILE_DEV_CODEGEN_UNITS="$CGU" \
      "$@"
    rc=$?
    local m; m=$(tail -n1 "$rss" 2>/dev/null | tr -dc '0-9')
    rm -f "$rss"
    if [ -n "$m" ] && [ "$m" -gt 0 ] 2>/dev/null; then
      exec 8>"$RSSL"; flock 8
      local prev; prev=$(cat "$RSSF" 2>/dev/null | tr -dc '0-9'); prev="${prev:-0}"
      [ "$m" -gt "$prev" ] && printf '%s' "$m" > "$RSSF"
      flock -u 8; exec 8>&-
    fi
    return $rc
  fi
  nice -n19 ionice -c3 env \
    CARGO_BUILD_JOBS="$JOBS" \
    CARGO_PROFILE_DEV_CODEGEN_UNITS="$CGU" \
    "$@"
}

# --- tell the server the clock should start NOW ---
# The dispatching run's hard watchdog is armed when the run starts, not when
# this script wins a slot. On a saturated semaphore that difference is the whole
# budget: waiters were killed with `Process lost` having compiled nothing. On
# admission we ask the server to restart the timeout, so the queue wait is not
# billed against the build.
#
# STRICTLY BEST-EFFORT — it must never affect the build. Fires only when the
# adapter supplied the env (a hand-run `cargo-sem.sh` in an operator shell has
# none and silently skips), is capped at 5s, and swallows every outcome. A
# failed announce costs this run its extension, nothing more; do not make it
# fatal, and do not move it before the slot is held — announcing while still
# queued restarts the clock for a build that has not started.
announce_admission() {
  [ -n "${PAPERCLIP_API_URL:-}" ] && [ -n "${PAPERCLIP_API_KEY:-}" ] &&
    [ -n "${PAPERCLIP_RUN_ID:-}" ] || return 0
  curl -fsS --max-time 5 -X POST \
    "$PAPERCLIP_API_URL/api/heartbeat-runs/$PAPERCLIP_RUN_ID/watchdog-restart" \
    -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true
}

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

# Optional trace for starvation debugging: records ticket order and,
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
    [ -n "$DBG" ] && printf 'admit ticket=%s slot=%s jobs=%s cgu=%s t=%s\n' "$T" "$SLOT_IDX" "$JOBS" "$CGU" "$(date +%s.%N)" >> "$DBG"
    announce_admission
    break
  fi
  sleep "$POLL"                                            # front, but capacity full
done

run "$@"; rc=$?
exec 9>&-
exit "$rc"
