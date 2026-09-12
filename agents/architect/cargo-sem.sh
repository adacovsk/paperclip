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
# <crate> src/main.rs`, 47 min in) and 4.1 GB (`src/lib.rs`) — 12 GB live,
# 642 MB free of 31 GB, and into swap. The big linking rustc for this crate is
# the outlier, not the dependency rustc (~0.2-0.3 GB each), so worst case scales
# with SLOTS: 3 slots x ~8 GB is ~24 GB on a 31 GB box that also holds ~12 GB of
# page cache. Do NOT raise SLOTS on the assumption that only cores are scarce —
# swapping a build box is worse than serializing it.
#
# CGU DOES NOT WORK THE WAY THIS HEADER USED TO CLAIM, AND THE CLAIM WAS THE
# WRONG WAY ROUND. It said "fewer codegen units means fewer LLVM modules live at
# once, so dropping CGU relieves memory pressure as well as thread pressure",
# and the default was derived downward from it. A benchmark on this box (same
# work: `cargo test --lib --no-run` in the main checkout, same CARGO_SEM_JOBS=2,
# express lane so it jumped no running build, only CGU varied, both rc=0):
#
#     CGU=1    10784s (179m)   peak RSS 12.09 GB
#     CGU=16    4422s  (73m)   peak RSS  7.58 GB
#
# Dropping CGU cost 2.5x wall time *and* 4.5 GB more peak RSS. Fewer, larger
# codegen units make each LLVM module bigger, and the biggest module is what
# sets the peak — so the low end is worse on both axes, not a memory/speed
# trade. Do NOT re-derive CGU downward "to relieve memory": that is the claim
# the data contradicts.
#
# STATE THE GAP RATHER THAN OVERSTATING THE RESULT: the arms were 1 and 16, and
# 16 is now the default, so this establishes the low end is bad and does not by
# itself establish 16 over an intermediate value. A 4-vs-16 arm is the missing
# measurement and is what to run before moving the default again. Per this
# header's own instruction — measure before trusting a bigger number.
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
#   CGU   = 16, declared       (cargo's non-incremental default; floor CGU_FLOOR)
# each floored as noted. On this 4-core/8-thread box the memory ceiling binds
# first, so it is 1 slot x 2 jobs x 16 units — the CPU derivation would allow 3.
# CGU is not part of the thread product — see the JOBS x CGU block for why.
# MEMORY IS ALSO A DERIVED CEILING, not just a warning in this header. SLOTS is
# additionally capped by (MemTotal x MEMPCT) / MEM_PER_BUILD — two declared
# numbers, so the cap is known before the first build rather than discovered
# after one. It only ever *lowers* the CPU-derived count. An earlier revision
# derived the divisor from measured peak RSS over a rolling window; that made
# the ceiling a moving, reactive target and is documented as a defect in the
# memory-budget block below. Portability is unchanged — a box with the same
# cores and a third of the RAM declares its own MEM_PER_BUILD.
#
# Override via CARGO_SEM_SLOTS / CARGO_SEM_JOBS / CARGO_SEM_CGU; raising SLOTS
# toward the logical-core count on this chip is expected to be slower, not faster
# (measure before trusting a bigger number). If the box still thrashes, drop
# SLOTS or JOBS — NOT CGU. This line used to name CGU as "the cheapest lever to
# drop next (2, then 1)"; measured on this box, CGU=1 cost 123 min and 11.5 GiB
# against CGU=16 at 67 min and 7.2 GiB for the same build. Lowering CGU makes a
# build slower AND larger, because one codegen unit is one undivided LLVM module.
#
# CGU is exported as CARGO_PROFILE_DEV_CODEGEN_UNITS rather than committed to
# the project's Cargo.toml on purpose. It must NOT apply to a human's dev build:
# workspace crates compile incrementally at 256 units, and lowering that
# coarsens rebuilds and slows the edit-compile-run loop. Fleet builds are
# non-incremental, so they lose nothing. (Dependencies are a different case and
# are capped in the project's [profile.dev.package."*"] — cargo never builds them
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
# EXPRESS LANE (CARGO_SEM_PRIORITY=1). Strict FIFO has one pathological case: a
# red `main` gates every verify, but the ci-fix that would clear it draws a
# ticket like everything else and queues behind builds whose results are already
# known to be worthless. Measured: the ci-fix sat 6th while all three slots were
# held by verifies their own tasks had since moved to `blocked`. An express
# waiter registers an extra presence lock; normal waiters yield before taking a
# slot, and the express waiter skips the FIFO gate rather than waiting its turn
# behind the very waiters that are yielding to it (doing both deadlocks — that
# was the first attempt). It never advances `serving`, so ordering among normal
# waiters is untouched, and it cannot preempt a build already holding a slot:
# that would discard real work, so it still waits for the first slot to free.
# Use it only for builds that gate the whole pipeline; a flood of express work
# would starve the normal lane by design.
#
# RESUME LANE (AA-3129) — a verify that has finished a stage outranks one that
# has not started. One verify is several cargo commands (`clippy --all-targets`,
# `test --lib`, `clippy --no-default-features`, `test --tests`), and each is a
# separate call to this script, because chaining them into one call is refused
# (see the ONE CARGO PER ACQUISITION guard below; do not "fix" this by lifting
# that ban — it is what bounds hold duration). Under strict FIFO that means a
# verify releases its slot between stages and re-enters at the BACK, behind
# every waiter that arrived while it was building.
#
# Measured: a task passed clippy and `test --lib` in six minutes of slot time,
# then sat behind 22 wrappers for its third stage; another had its clippy result
# sit complete and unused for 3h26m while it queued for `test --lib`. At depth N
# a verify pays 3-4 full queue drains, so wall-clock is dominated by re-queuing
# rather than by compiling — and the in-flight count stays high, which is what
# keeps the queue deep in the first place.
#
# NOTE WHAT DOES NOT WORK, because it is the obvious idea: having the releasing
# stage draw its next ticket BEFORE releasing. Its next ticket is still drawn
# after every waiter that queued up during the build, so it lands at the back
# anyway. The position a resuming stage needs is ahead of waiters that have not
# started, and no single monotonic counter can express that.
#
# So the resume lane is a SECOND ticket queue with its own counters, sitting
# between express and normal:
#   * A stage that follows a successful stage from the same worktree queues in
#     the resume lane, strictly FIFO among resumers by their own tickets.
#   * Normal waiters yield to any live resumer, exactly as they already yield to
#     express. Resumers yield to express. Express yields to nobody. The
#     precedence is a total order, so no two lanes can wait on each other.
#   * A resumer never touches `serving`, so ordering among normal waiters is
#     unchanged, and it cannot preempt a build already holding a slot.
#
# KEYED BY WORKTREE, so no caller opts in. The per-worktree mutex below already
# guarantees at most one build per worktree, so "the next cargo from this
# worktree" is exactly "the next stage of this chain". The verify scope template
# and every other caller are unchanged.
#
# THREE BOUNDS, because a lane that always wins starves the one below it:
#   * HOPS (CARGO_SEM_RESUME_MAX, default 4). A chain may hand off its
#     precedence this many times, then queues normally. So each normal admission
#     can spawn at most four resume admissions and normals keep a fifth of
#     throughput in the worst case — while in practice the lane finishes work
#     that is already half-paid-for and then empties.
#   * GRACE (CARGO_SEM_RESUME_GRACE, seconds). The marker a finishing stage
#     leaves expires. It has to hold the position across the handoff gap — stage
#     N+1 starts only after stage N's process exits, and normal waiters are
#     spinning — so while it is unexpired, normals yield to it. That is the
#     mechanism's whole cost, and it is idle slots: a chain that has ended, or a
#     one-off cargo, blocks the queue head until its marker lapses. Hence a few
#     seconds, not tens.
#   * SUCCESS ONLY. A failed stage ends the `&&` chain, so there is nothing to
#     resume.
# Self-healing is unchanged: a resumer's queue position is an flock, so a dead
# resumer is stepped over by the same probe the normal lane uses. Losing the
# marker file only costs a chain its precedence. CARGO_SEM_RESUME=0 disables it.
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
# throwaway liveness probe (subshell-scoped); fd 3 = the per-worktree mutex,
# taken before any ticket is drawn and held for the same lifetime as fd 9.
#
# We deliberately do NOT `taskset`-pin slots to disjoint core sets (the old 2-slot
# design pinned 0-3 / 4-7). On 4 cores that partitioning both fails to divide
# cleanly for N!=2 and strands cores idle when one build is in a serial link
# phase; `nice -n19` for priority plus the per-build job cap is the better fit.
# Override the state dir with CARGO_SEM_DIR and the poll interval with
# CARGO_SEM_POLL.
#
# Usage: cargo-sem.sh <command> [args...]

# --- RUN FROM A PRIVATE SNAPSHOT (do not remove; this is not a style choice) ---
# bash does not slurp a script. It reads incrementally and remembers a byte
# OFFSET into the open file. Rewrite this file in place and every running
# instance resumes at its old offset inside the NEW bytes, landing mid-token:
#
#   cargo-sem.sh: line 575: syntax error near unexpected token `&&'
#
# while `bash -n cargo-sem.sh` on the same file is clean. The semaphore was never
# broken — the file moved underneath live readers. Every wrapper blocked on the
# queue is a long-lived bash reading this file, and the queue routinely holds
# 8-10 wrappers for tens of minutes, so ONE edit can decapitate the whole verify
# queue at once. Worse, the wrapper dies without writing its exit sentinel, which
# the landing sweep reads as "the run never started" rather than "was killed" —
# so the diagnosis costs a fire on top of the lost build. (Observed: commit
# 221dc905f, which lost AA-4871's build and needed a re-dispatch on AA-4898.)
#
# So: copy ourselves to a temp file, re-exec from it, and immediately unlink the
# copy. bash holds the open fd, so an unlinked file still reads correctly and
# disappears on exit — the running instance is then reading bytes that NOTHING
# can rewrite, and the file on disk can be edited freely at any time.
#
# This must stay the FIRST executable statement: any code above it is still read
# from the mutable file. Keep the block itself short for that reason.
if [ -z "${CARGO_SEM_PINNED:-}" ]; then
  _sem_snap="$(mktemp "${TMPDIR:-/tmp}/cargo-sem.XXXXXXXX" 2>/dev/null)" || _sem_snap=""
  if [ -n "$_sem_snap" ] && cat -- "$0" > "$_sem_snap" 2>/dev/null; then
    CARGO_SEM_PINNED="$_sem_snap"
    export CARGO_SEM_PINNED
    exec bash "$_sem_snap" "$@"
  fi
  # mktemp or the copy failed. Run unpinned rather than failing the build: an
  # in-place edit during this run is a risk, being unable to build at all is a
  # certainty. Announce it so a syntax error here is not misread as a real one.
  [ -n "$_sem_snap" ] && rm -f -- "$_sem_snap"
  printf 'cargo-sem: WARNING could not snapshot %s; running unpinned (an in-place edit will kill this run)\n' "$0" >&2
else
  # Second entry, reading from the snapshot. bash already holds the fd, so
  # unlinking now is safe and makes the copy self-cleaning even on SIGKILL.
  rm -f -- "$CARGO_SEM_PINNED"
fi

set -u

D="${CARGO_SEM_DIR:-/tmp}"
POLL="${CARGO_SEM_POLL:-0.2}"
NPROC="$(nproc 2>/dev/null || echo 4)"
# Physical cores (hyperthreads collapsed) — the real parallelism ceiling. Count
# distinct core ids from lscpu; fall back to nproc where lscpu is unavailable.
PHYS="$(lscpu -p=core 2>/dev/null | grep -v '^#' | sort -u | grep -c '' 2>/dev/null)"
[ "${PHYS:-0}" -ge 1 ] 2>/dev/null || PHYS="$NPROC"
# =========================== CAPACITY DERIVATION ============================
#
# DECLARE THE BUDGETS, DERIVE THE KNOBS — in that order, in this one block.
#
# The header above is emphatic that the lever is the PRODUCT, SLOTS x JOBS x
# CGU. An earlier revision nonetheless derived all three *independently* from
# core counts and then patched SLOTS for memory sixty lines further down. Two
# defects followed from that shape, and both are structural rather than
# mis-tuning:
#
#   1. ORDERING. JOBS was computed from SLOTS *before* the memory cap lowered
#      SLOTS, so it described a slot count that no longer existed. Measured on
#      this box: JOBS=2 (from 8/3) while 2 slots actually ran — the box
#      simultaneously under-jobbed each build and over-threaded the machine.
#
#   2. THE PRODUCT WAS NEVER EXPRESSED. Nobody chose it; it fell out. This box
#      landed on 3x2x4 = 24 threads on 4 physical cores (6x oversubscription),
#      and 2x2x4 = 16 after the cap. Neither number was a decision, and the
#      header's own bug report — 37 threads, desktop unusable — was the same
#      defect one revision earlier. A quantity that is never named cannot be
#      tuned, only overridden from outside, which is why every correction to
#      this script arrived as a CARGO_SEM_* exception.
#
# So the inputs are now the two things the hardware actually bounds — a THREAD
# budget and a MEMORY budget — and SLOTS/JOBS/CGU are consequences. SLOTS is
# final before anything derives from it. The product is invariant by
# construction, so hitting a different target means changing a budget, not
# bolting on another exception.
#
# THREAD BUDGET. Default NPROC: do not run more compile threads than the
# machine has hardware threads. Oversubscription past ~1x buys churn, cache
# thrash and heat — and on a 15 W ULV part heat means throttling, so the
# marginal thread makes the other builds slower. `nice -n19`/`ionice -c3`
# already handle desktop priority; they do not make excess threads free.
THREADS="${CARGO_SEM_THREADS:-$NPROC}"
[ "$THREADS" -ge 1 ] 2>/dev/null || THREADS="$NPROC"

# MEMORY BUDGET, and the slot ceiling that falls out of it.
#
# TWO DECLARED NUMBERS, NO MEASUREMENT IN THE LOOP. The budget is a percentage
# of MemTotal; the per-build cost is a constant. SLOTS follows from dividing
# one by the other, and is therefore known before the first build of the day
# rather than discovered after one.
#
# WHY NOT DERIVE THE DIVISOR FROM MEASURED RSS — this was the previous design
# and it is the defect this section replaces. run() measured every build's peak
# RSS and the ceiling was MemTotal x MEMPCT divided by the max over a rolling
# window of recent builds. Three things were wrong with it, and they compound:
#
#   1. IT MEASURED A MOVING TARGET. Peak RSS is a property of the *command*,
#      not the machine. Measured on this box within one hour: four builds at
#      ~4.0 GiB and one at 11.5 GiB, a 3x spread, because `cargo test --lib
#      --no-run` also links test harnesses while `cargo clippy` does not. The
#      cap therefore swung between 5 and 1 depending on which command types
#      happened to occupy the window — a quantity with no hardware meaning.
#   2. IT WAS REACTIVE, SO IT COULD NOT PREVENT THE FIRST THRASH. The ceiling
#      only tightened after a large build had been recorded, and forgot it
#      WINDOW builds later. Measured: three 6-7 GiB compiles were admitted
#      concurrently while the window held only ~4 GiB entries, drove the box
#      20 GiB into swap, and earlyoom killed four rustc over six hours -- one
#      roughly every hour, each one a verify that had to start over. Builds
#      churned for ~20 hours without producing a verdict.
#   3. A SINGLE OUTLIER STILL MOVED THE CAP HARD. The window bounded how *long*
#      an outlier persisted, not how much it distorted. One 11.5 GiB entry took
#      memslots to 1 immediately; before the window existed, a 10.90 GiB entry
#      pinned it at 1 permanently and drained the queue for days with two of
#      three slots idle.
#
# So the divisor is now declared. MEM_PER_BUILD states the worst command type's
# cost, not the average and not the last one observed, because the ceiling has
# to survive whatever is admitted next. Portability is unaffected: a different
# box declares a different number, and the recorded peaks below are what tell
# you which number to declare. What changes is that the recording no longer
# feeds back into the live cap.
#
# MemTotal, not MemAvailable: every caller must agree on capacity or they would
# disagree about how many slot locks exist. MemTotal is stable; MemAvailable
# moves as builds start, so deriving from it would let two concurrent callers
# compute different SLOTS. Two constants divided into a stable number are
# stable in the same sense, and now trivially so.
#
# NOT ALL OF MemTotal IS THE BUILD'S TO SPEND. This is a desktop, not a
# dedicated build box: a browser, an editor, postgres and the Paperclip server
# share it, plus the page cache that makes the builds themselves fast. Dividing
# the WHOLE of MemTotal by the peak build handed every byte to cargo. Measured
# failure: MemTotal 31.1 GiB / peak 9.35 GiB = 3, the CPU derivation was also
# 3, so the ceiling lowered nothing and three slots were admitted at ~9.35 GiB
# each = 28 GiB of rustc before the desktop got a byte. Result was a 35-minute
# OOM storm — 14 oom-killer invocations, all 4 GiB of swap exhausted, rustc
# killed twice at ~7.9 GiB, and a dozen browser processes taken as collateral
# because they carry a higher oom_score_adj.
#
# Hence a PERCENTAGE of MemTotal. The default reserves ~30% (~9 GiB here) for
# everything that is not a build, sized to what the desktop plus page cache was
# actually holding when the box went over. Raising it toward 100 re-creates the
# storm; lowering it serializes builds, which is the safe direction — swapping a
# build box is worse than queueing it.
RSSF="$D/cargo-sem.peak-rss"
RSSL="$D/cargo-sem.rss.lock"
# The rolling window's high-water mark, which never rotates. $RSSF answers "what
# have recent builds cost"; this answers "what is the worst this box has ever
# handed a build", which is the only one of the two questions MEM_PER_BUILD is
# derived from. Keeping them in separate files is what stops a window full of
# light `clippy` runs from reading as evidence that the heavy stage got cheaper.
# NOT under $D. $D defaults to /tmp, and a mark that resets on reboot is one a
# quiet window can outlive — which is the whole failure this file exists to
# close. It feeds nothing (SLOTS derives from MemTotal and the two declared
# constants), so it carries none of the "every caller must agree" constraint
# that pins the rest of the state directory, and it is free to be durable.
RSSMAXF="${CARGO_SEM_RSS_MAX_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify/cargo-sem.peak-rss.max}"
mkdir -p "$(dirname "$RSSMAXF")" 2>/dev/null || true
# How many recent builds to KEEP for reporting. This no longer feeds the cap —
# it is the evidence you read when deciding whether MEM_PER_BUILD is still the
# right declaration for this box.
#
# KEEP ENOUGH TO OUTLIVE THE ARGUMENT. At 5 entries this file rotated within
# hours, and a run of light `clippy` builds was enough to flush every heavy
# `test --lib` peak out of it. The declaration below then had nothing to check
# it against, and the absence of the cited peaks was read as evidence they had
# never existed — a proposal to lower MEM_PER_BUILD and admit a second build
# rested on it. A retention window shorter than the interval between arguments
# about the constant makes the constant unfalsifiable. 25 spans a full day of
# verifies, and the file is 25 lines.
RSSWIN="${CARGO_SEM_RSS_WINDOW:-25}"
[ "$RSSWIN" -ge 1 ] 2>/dev/null || RSSWIN=25
MEMPCT="${CARGO_SEM_MEM_PCT:-70}"
[ "$MEMPCT" -ge 1 ] 2>/dev/null && [ "$MEMPCT" -le 100 ] || MEMPCT=70
# Declared worst-case peak RSS of one build, in kB. 11 GiB, from recorded peaks
# — carried here as raw kB, the unit $RSSF is written in, so they stay checkable
# after the window has rotated past them:
#
#   11484736 kB  10.95 GiB   consecutive verifies, each warning against the
#   10551360 kB  10.06 GiB   then-declared 8 GiB
#   11541284 kB  11.01 GiB   one window held four entries above 10.6 GiB:
#   11476760 kB  10.95 GiB   11541284, 11476760, 11387272, 11209436, with a
#   11387272 kB  10.86 GiB   fifth at 8392532 (8.00 GiB)
#   11209436 kB  10.69 GiB
#
# and 8.1-8.5 GiB as the routine cost of the `test --lib` stage. Every figure
# above is a `test --lib` peak recorded WITH `CARGO_SEM_CGU_DIV=2` already
# applied — the wrappers pass it on that stage unconditionally — so 11 GiB is
# the cost of the cheaper spelling of the heaviest stage, not of an untuned one.
#
# On this box that yields (31.06 GiB x 70%) / 11 GiB = 1 slot; JOBS is unchanged
# at 2, because the sqrt split below returns 2 for a per-slot budget of both 4
# and 8 threads.
#
# THE MARGIN TO 2 SLOTS IS NOT SLACK. Two slots need MEM_PER_BUILD <= 11398906
# kB (10.87 GiB), which the derivation misses by 1.17% — close enough to read as
# a rounding artifact worth tuning away, and that reading has been proposed. It
# is backwards: the recorded maximum is 11541284 kB, which is ABOVE the 11 GiB
# declared here, so the declaration is already slightly optimistic. Lowering it
# to buy the second slot would admit 2 x 11.01 GiB = 22.0 GiB against a 21.74
# GiB budget — i.e. declaring a ceiling the measurements exceed on arrival.
# That is the configuration whose consequences are recorded above: 7 GiB
# available of 31 with 7 GiB of swap in use, wrappers alive 38h, and the
# Coordinator holding every dispatch because the census never drained. If the
# queue is the problem, the lever is the cloud-overflow lane or a cheaper
# heaviest stage, not a second slot this box's memory cannot pay for.
#
# This was 8 GiB, which sat in the GAP of a bimodal distribution rather than
# above it: `clippy` peaks ~3.9 GiB and the `test --lib` link ~8.1-11 GiB, so
# every heavy build ended by warning that the constant underneath it was wrong,
# while the memgate went on admitting two of them against a budget that fits
# one. A declaration that the thing it governs contradicts on every run is not a
# ceiling, it is a comment.
#
# WORST CASE MEANS WORST CASE, and this number is not the ceiling of rustc's
# appetite — it is the ceiling of what this box's cores let rustc reach. A
# single rustc has been observed at ~20 GiB on a cloud-overflow VM, which runs
# the same crate with no semaphore and no CGU override on more cores: more LLVM
# modules resident at once inside one process. Nothing here bounds that (the VM
# lane does not call this script at all — see docs/ARCHITECT_CLOUD_OVERFLOW.md),
# but it is the reason not to read the local record as "big builds cost 8 GiB".
# Given cores, the same compile will take four times that.
#
# Raise it only with recorded peaks in hand. $RSSF holds the recent window and
# $RSSMAXF the high-water mark; the second is the one this constant answers to.
#
# READ $RSSMAXF BEFORE PROPOSING A CHANGE TO THIS NUMBER. $RSSF is a rolling
# window, so a run of light `clippy` builds flushes every heavy `test --lib`
# peak out of it, and the window then shows a maximum far below the declaration.
# That reading — "the recorded peaks are all under MEM_PER_BUILD, so it was
# rounded up" — is the argument the block above refutes, and it is reachable
# from $RSSF alone at any moment. It is not reachable from $RSSMAXF, which only
# ever rises. The measurement this constant rests on is named above in prose;
# $RSSMAXF is where the box keeps checking it.
MEM_PER_BUILD="${CARGO_SEM_MEM_PER_BUILD:-11534336}"
[ "$MEM_PER_BUILD" -ge 1 ] 2>/dev/null || MEM_PER_BUILD=11534336
# Lowest codegen-unit count any stage may be reduced to. 8: measured, CGU=1 cost
# 2x the wall clock and 4.3 GiB more peak RSS than CGU=16 on this crate, so the
# low end of this knob is where builds get slow enough to be OOM-killed.
CGU_FLOOR="${CARGO_SEM_CGU_FLOOR:-8}"
[ "$CGU_FLOOR" -ge 1 ] 2>/dev/null || CGU_FLOOR=8

# derive_limits — SLOTS, then JOBS x CGU, from the ceilings as they stand NOW.
#
# A FUNCTION, not a one-shot, because the memory ceiling it reads is designed to
# move: `$RSSF` is a rolling window of recent builds, so `_peak` — and therefore
# SLOTS — changes as builds finish. Resolving it once at launch meant a
# long-lived waiter kept enforcing whatever ceiling was true when it started,
# and a stale-low waiter at the FIFO head pinned every ticket behind it (the
# strict no-overtake rule below means the queue does not run slow, it stops).
#
# Re-deriving inside the admission loop does not break the agreement the header
# above requires. That invariant is "every caller reading at a given moment
# derives the same SLOTS" — a property of the inputs (MemTotal is stable, and
# the window file changes only when a build finishes), not of when the reading
# happens. Callers converge on each other as the window moves rather than each
# holding its own launch-time snapshot.
#
# JOBS and CGU are re-derived with it, deliberately: they are the per-slot
# thread budget and are meaningless against a slot count that no longer exists.
# Computing them from a stale SLOTS is the ordering bug the header records as
# already having been made once.
derive_limits() {
  # SLOTS — the one quantity bounded by BOTH ceilings, so it resolves first.
  # Cores: one build per physical core, less one reserved for the OS, sccache and
  # the Paperclip orchestration sharing this box; floor of 2. Memory: how many
  # worst-observed builds fit in the budget. The lower wins. An explicit
  # CARGO_SEM_SLOTS is a decision, not an estimate, and beats both.
  _cpuslots=$(( PHYS - 1 < 2 ? 2 : PHYS - 1 ))
  _memslots="$_cpuslots"
  _memkb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${_memkb:-0}" -gt 0 ] 2>/dev/null; then
    _memslots=$(( (_memkb * MEMPCT / 100) / MEM_PER_BUILD ))
    [ "$_memslots" -ge 1 ] || _memslots=1
  fi
  SLOTS="${CARGO_SEM_SLOTS:-$(( _memslots < _cpuslots ? _memslots : _cpuslots ))}"
  [ "$SLOTS" -ge 1 ] 2>/dev/null || SLOTS=1

  # PUBLISH THE CEILING. The number is derived here from hardware the caller
  # cannot see, and the layer that decides how much work to hand us — Coordinator's
  # verify dispatch — has no other way to learn it. Left unpublished it gets
  # guessed, and the guess goes stale exactly when it matters: the "physical
  # cores - 1" figure quoted in Coordinator's INSTRUCTIONS said 3 while the memory
  # budget had already lowered this to 2, so a cap built on the quoted number
  # would license 50% more in-flight builds than the box can admit. Best-effort:
  # a read-only /tmp must not fail a build.
  printf '%s\n' "$SLOTS" > "$D/cargo-sem.slots" 2>/dev/null || true

  # JOBS carries the per-slot thread budget. CGU does NOT — see below.
  #
  # This block used to split the budget evenly between the two on the model that
  # SLOTS x JOBS x CGU is a thread count. MEASURED, and the model is wrong for
  # the CGU factor: codegen workers draw from cargo's jobserver, so CGU sets how
  # many LLVM modules the crate is *divided into*, not how many threads run at
  # once. A CGU=16 build was observed with two rustc at 50-65% CPU, not sixteen
  # threads. Treating CGU as a thread multiplier therefore bought no thread
  # relief and cost double on both axes that matter:
  #
  #   cargo test --lib --no-run, warm target, same box, same JOBS=2:
  #     CGU=1     123 min    11.5 GiB peak RSS
  #     CGU=16     67 min     7.2 GiB peak RSS
  #
  # Both directions follow from the same fact. One codegen unit means the whole
  # crate is one LLVM module: nothing to parallelise, and the entire module live
  # at once. The header's old advice — "if the box still thrashes, CGU is the
  # cheapest lever to drop next (2, then 1)" — is exactly backwards, and it is
  # what put builds at 1-2 units where they took ~2 hours and peaked high enough
  # for earlyoom to reap them mid-compile. Do not restore it.
  #
  # So CGU is declared at cargo's own non-incremental default and JOBS takes the
  # whole per-slot budget. JOBS remains the memory-expensive lever (each job is
  # another whole rustc), which is why it, not CGU, is what the budget bounds.
  _per_slot=$(( THREADS / SLOTS ))
  [ "$_per_slot" -ge 1 ] || _per_slot=1
  _split=1
  while [ $(( (_split + 1) * (_split + 1) )) -le "$_per_slot" ]; do _split=$(( _split + 1 )); done
  JOBS="${CARGO_SEM_JOBS:-$_split}"
  CGU="${CARGO_SEM_CGU:-16}"
  [ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
  [ "$CGU" -ge 1 ] 2>/dev/null || CGU=16

  # Stage-relative cut. CARGO_SEM_CGU_DIV divides whatever CGU resolved to above,
  # floored at 1, so a caller can say "this stage is the heavy one, give it less"
  # without embedding a number tuned to one machine. The test stage passes 2 (see
  # the Architect INSTRUCTIONS launch block) for the same *proportional* relief on
  # any box. Divides an explicit CARGO_SEM_CGU too, so "half whatever this box
  # decided" holds however CGU was arrived at.
  CGU=$(( CGU / ${CARGO_SEM_CGU_DIV:-1} ))
  # ...but never below CGU_FLOOR. The divisor exists to make a heavy stage
  # proportionally lighter, and under the old thread model driving it toward 1
  # looked like relief. It is not: 1-2 units is where the 123-minute, 11.5 GiB
  # builds above came from, and the test stage's CGU_DIV=2 is precisely what
  # produced them. Keep the knob — a caller asking for proportionally less is
  # still meaningful — but stop it landing in the range the measurement rejects.
  [ "$CGU" -ge "$CGU_FLOOR" ] 2>/dev/null || CGU="$CGU_FLOOR"
  [ "$CGU" -ge 1 ] || CGU=1
}

derive_limits

CTL="$D/cargo-sem.ctl.lock"
NEXT="$D/cargo-sem.next"
SERV="$D/cargo-sem.serving"
WAIT="$D/cargo-sem.wait"
EXP="$D/cargo-sem.express"
PRIO="${CARGO_SEM_PRIORITY:-0}"
# --- resume lane (see header) ---
RNEXT="$D/cargo-sem.rnext"     # the resume lane's own ticket counter...
RSERV="$D/cargo-sem.rserving"  # ...and its own low-water mark
RWAIT="$D/cargo-sem.rwait"     # $RWAIT.<ticket>, a resumer's presence lock
MARK="$D/cargo-sem.chain"      # $MARK.<worktree key> -> "<deadline epoch> <hops>"
RESUME="${CARGO_SEM_RESUME:-1}"
# Seconds a chain marker stays valid. This is the mechanism's one real cost, and
# it is paid in IDLE SLOTS rather than latency: normal waiters yield while a
# marker is unexpired, so the last stage of every chain — and every one-off
# cargo — blocks the queue head until its marker lapses. Keep it just long
# enough to cover the handoff, which is a `&&` in one shell plus at most a `git
# diff`. Five seconds against builds measured in tens of minutes buys back 2-3
# full queue drains per verify; do not raise it without re-measuring that trade.
GRACE="${CARGO_SEM_RESUME_GRACE:-5}"
[ "$GRACE" -ge 1 ] 2>/dev/null || GRACE=5
# How many hand-offs one chain may use the lane for. The longest verify is four
# stages, so it needs three; 4 leaves headroom for a trailing command such as a
# schema regeneration. Past it the chain queues normally, which is what keeps a
# worktree looping on cargo from holding permanent precedence.
RESUME_MAX="${CARGO_SEM_RESUME_MAX:-4}"
[ "$RESUME_MAX" -ge 0 ] 2>/dev/null || RESUME_MAX=4

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

# --- CPU must not be parked in a power-saving profile ---
# `powerprofilesctl set performance` is RUNTIME state: it does not survive a
# reboot, and power-profiles-daemon has already drifted this AC-powered box to
# `power-saver` once on its own. Parked, every core pins at 800 MHz against a
# 4.2 GHz ceiling — 19% — and every verify runs ~3.5x slow.
#
# That regression is silent, which is the whole problem. Nothing fails; wall
# clock just creeps, and a build that should take 40 min takes 2h19m. It went
# unnoticed for days, and was eventually found only by measuring the box while
# chasing a different bug. So detect it here, where every Architect build passes.
#
# WARN, never block. A slow build is worth running; a build that refuses to start
# because a laptop is on battery is not. The point is to make the cause visible
# in the log the moment it costs time, instead of leaving wall-clock creep as the
# only signal. Set CARGO_SEM_SKIP_EPP_CHECK=1 to silence (deliberate battery
# operation), and prefer fixing persistence — a boot-time
# `powerprofilesctl set performance`, or a systemd unit — over silencing.
if [ "${CARGO_SEM_SKIP_EPP_CHECK:-0}" != "1" ] && command -v powerprofilesctl >/dev/null 2>&1; then
  _profile="$(powerprofilesctl get 2>/dev/null || echo unknown)"
  if [ "$_profile" != "performance" ]; then
    _mhz="$(awk '/cpu MHz/{s+=$2==""?0:$4; n++} END{if(n)printf "%.0f", s/n}' /proc/cpuinfo 2>/dev/null)"
    printf 'cargo-sem.sh: WARNING — power profile is "%s", not "performance" (avg core %s MHz).\n' \
      "$_profile" "${_mhz:-?}" >&2
    printf '  Builds run ~3.5x slow parked at 800 MHz, and nothing fails — the only\n' >&2
    printf '  symptom is wall-clock creep, which took days to notice last time.\n' >&2
    printf '  Fix:  powerprofilesctl set performance   (runtime only — make it persist)\n' >&2
    printf '  Silence: CARGO_SEM_SKIP_EPP_CHECK=1\n' >&2
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
#
# THIS RECORD IS EVIDENCE, NOT AN INPUT. It does not feed SLOTS — MEM_PER_BUILD
# is declared, for the reasons in the memory-budget block above. What it does is
# tell you when that declaration has gone stale: a build that exceeds it warns,
# and $RSSF keeps the last RSSWIN peaks so the next person to touch the constant
# is choosing from measurements rather than guessing. Do NOT reconnect it to the
# cap; a ceiling that moves under running builds is the defect this replaced.
# Strictly best-effort: no `/usr/bin/time`, no measurement, and nothing is lost
# but the warning. Never allowed to affect the build's exit status.
# THE BUILD RUNS WITH THE LOCK FDS CLOSED. Every lock that gates progress here
# is an flock, and an flock belongs to the open file description — so it lives
# as long as *any* fd on it stays open, in any process. The parent holds fds 3
# (per-worktree) and 9 (slot) for the build's whole duration, which is what
# makes the lock mean something; a child inheriting them adds nothing and can
# outlive us. Cargo cold-starts the sccache *server* when it is not already up,
# and that daemon detaches and stays resident: it inherits fd 9, and the slot is
# then held by a process that never exits. Capacity drops by one, permanently,
# and `reap_escaped_orphans` cannot help — its predicate matches rustc and cargo
# only, deliberately, because reaping a shared daemon is worse than the leak.
# The pre-start above is the first line of defence and is not sufficient on its
# own: a waiter pre-starts the server, then queues (measured: over three hours
# on a deep FIFO), the server passes its idle timeout and exits, and the build
# that finally wins the slot cold-starts it again from *under* the lock.
# Closing the fds in the child makes the whole class impossible rather than
# racing it, and costs the build nothing — it never reads them.
run() {
  local rss="$D/.rss.$$" rc=0
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -f '%M' -o "$rss" \
      nice -n19 ionice -c3 env \
      CARGO_BUILD_JOBS="$JOBS" \
      CARGO_PROFILE_DEV_CODEGEN_UNITS="$CGU" \
      "$@" 3>&- 5>&- 7>&- 9>&-
    rc=$?
    local m; m=$(tail -n1 "$rss" 2>/dev/null | tr -dc '0-9')
    rm -f "$rss"
    if [ -n "$m" ] && [ "$m" -gt 0 ] 2>/dev/null; then
      if [ "$m" -gt "$MEM_PER_BUILD" ] 2>/dev/null; then
        printf 'cargo-sem.sh: build peaked at %s kB, above the declared MEM_PER_BUILD of %s kB; SLOTS may be too high for this workload.\n' \
          "$m" "$MEM_PER_BUILD" >&2
      fi
      exec 8>"$RSSL"; flock 8
      { awk '{gsub(/[^0-9]/," "); for(i=1;i<=NF;i++) print $i}' "$RSSF" 2>/dev/null; \
        printf '%s\n' "$m"; } \
        | awk 'NF' | tail -n "$RSSWIN" > "$RSSF.new" 2>/dev/null \
        && mv -f "$RSSF.new" "$RSSF"
      # Raise the high-water mark under the same lock. This is the record
      # MEM_PER_BUILD answers to; the window above rotates and cannot be.
      _cur=0
      [ -r "$RSSMAXF" ] && _cur=$(tr -dc '0-9' 2>/dev/null < "$RSSMAXF")
      [ -n "$_cur" ] || _cur=0
      if [ "$m" -gt "$_cur" ] 2>/dev/null; then
        printf '%s\n' "$m" > "$RSSMAXF.new" 2>/dev/null \
          && mv -f "$RSSMAXF.new" "$RSSMAXF"
      fi
      unset _cur
      flock -u 8; exec 8>&-
    fi
    return $rc
  fi
  nice -n19 ionice -c3 env \
    CARGO_BUILD_JOBS="$JOBS" \
    CARGO_PROFILE_DEV_CODEGEN_UNITS="$CGU" \
    "$@" 3>&- 5>&- 7>&- 9>&-
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
#
# The API key is OPTIONAL, deliberately. The adapter injects PAPERCLIP_API_KEY
# only for agents configured with the `paperclip` skill, so gating on it makes
# this a silent no-op for any agent without that skill — which is the normal
# configuration for a build-only agent, and turns the announce into dead code
# exactly where it is needed. In Local Trusted Mode (loopback requests are the
# operator) the call authenticates without a key. Send the header when a key IS
# present; never gate on it.
api_post() {
  local path="$1" body="$2"
  [ -n "${PAPERCLIP_API_URL:-}" ] || return 1
  if [ -n "${PAPERCLIP_API_KEY:-}" ]; then
    curl -fsS --max-time 5 -X POST "$PAPERCLIP_API_URL$path" \
      -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
      -H "Content-Type: application/json" -d "$body" 2>/dev/null
  else
    curl -fsS --max-time 5 -X POST "$PAPERCLIP_API_URL$path" \
      -H "Content-Type: application/json" -d "$body" 2>/dev/null
  fi
}

announce_admission() {
  [ -n "${PAPERCLIP_RUN_ID:-}" ] || return 0
  api_post "/api/heartbeat-runs/$PAPERCLIP_RUN_ID/watchdog-restart" '{}' >/dev/null || true
}

# --- make the detached build visible ---
# The Architect dispatches this script and exits, so from the server's side a
# build that runs for hours holds no run at all: the issue shows no `Live` pulse
# and reads exactly like a task that never started — indistinguishable from the
# lost-sentinel failure. Opening a run against the issue lights up the existing
# UI (issue row, Kanban card, inbox) with no new surface to maintain.
#
# Same best-effort contract as announce_admission: the build is the point, the
# telemetry is not. Every failure path returns success and DETACHED_RUN_ID stays
# empty, which simply skips the close.
DETACHED_RUN_ID=""

open_detached_run() {
  [ -n "${PAPERCLIP_AGENT_ID:-}" ] && [ -n "${PAPERCLIP_API_URL:-}" ] || return 0
  local body out
  body=$(printf '{"agentId":"%s","issueId":"%s","pid":%s,"triggerDetail":"%s"}' \
    "$PAPERCLIP_AGENT_ID" "${PAPERCLIP_TASK_ID:-}" "$$" "$(printf '%s' "$*" | tr -d '"\\' | cut -c1-200)")
  out=$(api_post "/api/heartbeat-runs/detached" "$body") || return 0
  DETACHED_RUN_ID=$(printf '%s' "$out" | sed -n 's/.*"runId":"\([^"]*\)".*/\1/p')
}

# Closed from an EXIT trap, so a SIGTERM'd or SIGKILL'd-parent build still
# settles wherever the shell gets to run it. A build killed outright (the
# service-restart case) leaves the run open — that is the honest reading, and
# the reaper deliberately will not "tidy" it, since guessing here is what
# re-dispatches a healthy build.
close_detached_run() {
  [ -n "$DETACHED_RUN_ID" ] || return 0
  api_post "/api/heartbeat-runs/$DETACHED_RUN_ID/detached-finish" \
    "$(printf '{"exitCode":%s}' "${1:-1}")" >/dev/null || true
  DETACHED_RUN_ID=""
}

rd() { local v=0; [ -f "$1" ] && v=$(<"$1"); printf '%s' "${v:-0}"; }
wr() { printf '%s' "$2" > "$1"; }

# Is ticket $1 still a live waiter? Non-zero (false) once its owner has released
# the presence lock — by admission or by death. Probe is subshell-scoped so the
# fd (and any momentary acquire) is dropped immediately.
alive() { ! ( exec 4>"${2:-$WAIT}.$1"; flock -n 4; ) 2>/dev/null; }

# --- escaped-build orphans ---
# A rustc (or cargo) started under a verify wrapper can outlive both the wrapper
# and its systemd scope: when a *dispatching* run dies, its children are
# reparented to `systemd --user` and land in the `paperclip.service` cgroup
# instead of a `verifyrun-*.scope`. Nothing then owns them, and nothing reaps
# them. Measured instances held 7.7 GB, 8.5 GB and 21 GB of RSS while the real
# build for the same worktree ran normally alongside — five recurrences, each
# rediscovered from scratch because each was only ever written into a routine
# record that closed the moment it was written.
#
# THE COST IS THROUGHPUT, NOT JUST MEMORY. SLOTS is derived from available
# memory (see the capacity block), so one 8.5 GB orphan directly collapses the
# semaphore ceiling — and it is the same pressure that produces the earlyoom
# mass-kills and the SIGTERM-as-101 verify failures.
#
# IT ALSO WEDGES THE PER-WORKTREE LOCK. An orphan inherited the `exec 3>` fd of
# the cargo-sem.sh that spawned it, and an flock belongs to the *open file
# description*, not to a pid. `/proc/locks` reports only the pid that created
# the description, so a dead pid is reported holding a lock that a live orphan
# is really keeping open — which is why the "same self-healing property as every
# other lock in this script" note below is true only once the orphans are gone.
# A later stage of the same chain then spins on `flock 3` against a lock nothing
# legitimate is using: measured at 25m49s of a `sleep 0.2` loop on a chain that
# had already passed clippy and 3328 green tests.
#
# THE PREDICATE, and it is deliberately narrow — reaping a live build is far
# worse than leaving an orphan:
#   * command is rustc or cargo, and
#   * cwd is inside a `.paperclip/worktrees/` tree, and
#   * its cgroup is NOT a `verifyrun-*.scope` (a real build is always in one), and
#   * it was reparented (ppid 1) — nothing living supervises it.
# All four must hold. A build whose wrapper is alive fails the third; a child of
# a live cargo fails the fourth.
#
# `kill` WORKS HERE, AND DOES NOT WORK WHERE YOU MAY HAVE READ THAT IT DOESN'T.
# The Architect's INSTRUCTIONS say the sandbox denies `kill` (rule 7's "do NOT
# use kill -0"), and the Facilitator has recorded the same refusal. That applies
# to an *agent's* tool sandbox. This script runs inside the detached wrapper's
# own transient scope, outside that sandbox, which is exactly why the reaper
# belongs here rather than in any agent's instructions — the agents that keep
# finding these orphans are the ones that cannot kill them.
#
# THE MAIN CHECKOUT IS DELIBERATELY OUT OF SCOPE. The cwd term restricts this to
# `.paperclip/worktrees/`, so an escaped build in `$PAPERCLIP_PROJECT` itself is
# NOT reaped — and one has been observed there (an untracked `generate_schemas`
# chain armed by an operator session, ppid 1, cwd the main checkout). That is a
# deliberate exclusion, not an oversight: the main checkout is where an operator
# builds by hand, and killing their build to reclaim a slot is a worse failure
# than the slot. Such a process is reported by the routine sweeps and reaped by
# hand.
#
# Set CARGO_SEM_REAP_ORPHANS=0 to disable, or CARGO_SEM_REAP_DRYRUN=1 to report
# without killing (which is how to confirm the predicate on a new failure shape
# before trusting it).
# Returns 0 ONLY when it actually killed something, so a caller may use it as a
# "retry is worth it" signal. Disabled and dry-run both return 1: neither freed
# anything, and reporting otherwise would have the lock wait below print that it
# reaped its way in when it did not.
reap_escaped_orphans() {
  [ "${CARGO_SEM_REAP_ORPHANS:-1}" = "1" ] || return 1
  local p pid comm cwd cg ppid n=0
  for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    comm="$(cat "$p/comm" 2>/dev/null)" || continue
    case "$comm" in rustc|cargo) ;; *) continue ;; esac
    cwd="$(readlink -f "$p/cwd" 2>/dev/null)" || continue
    case "$cwd" in */.paperclip/worktrees/*) ;; *) continue ;; esac
    cg="$(cat "$p/cgroup" 2>/dev/null)"
    case "$cg" in *verifyrun-*) continue ;; esac
    # Reparented to init/systemd --user means nothing supervises it. Require the
    # field to be present AND equal 1 — a missing PPid must not read as orphaned.
    ppid="$(awk '$1=="PPid:"{print $2; exit}' "$p/status" 2>/dev/null)"
    [ "${ppid:-0}" = "1" ] || continue
    if [ "${CARGO_SEM_REAP_DRYRUN:-0}" = "1" ]; then
      printf 'cargo-sem.sh: WOULD REAP escaped %s pid=%s rss=%skB cwd=%s\n' \
        "$comm" "$pid" "$(awk '/^VmRSS:/{print $2}' "$p/status" 2>/dev/null)" "$cwd" >&2
      continue                                   # reported, not freed — see the return contract
    else
      printf 'cargo-sem.sh: reaping escaped %s pid=%s rss=%skB cwd=%s (no verifyrun scope, ppid 1)\n' \
        "$comm" "$pid" "$(awk '/^VmRSS:/{print $2}' "$p/status" 2>/dev/null)" "$cwd" >&2
      kill -9 "$pid" 2>/dev/null || true
    fi
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] && return 0
  return 1
}

# --- express lane (CARGO_SEM_PRIORITY=1) ---
# Is any *live* priority waiter queued? Same flock-presence trick as alive(), so
# it inherits the same self-healing: a dead express waiter's lock is dropped by
# the kernel, and its stale file is swept here rather than blocking the queue
# forever. Normal waiters consult this before taking a slot; express waiters do
# not, or they would yield to themselves.
express_waiting() {
  local f
  for f in "$EXP".*; do
    [ -e "$f" ] || continue
    if ! ( exec 4>"$f"; flock -n 4; ) 2>/dev/null; then return 0; fi
    rm -f "$f"
  done
  return 1
}

# --- resume lane ---
# Is a resumer queued, or about to be? Two things count, and the second is what
# makes the lane work at all:
#
#   * A live resume-lane presence lock. Same flock scan as express_waiting(),
#     self-healing for the same reason — a dead resumer's lock is dropped by the
#     kernel and its stale file is swept here.
#   * An unexpired chain marker, meaning a stage finished and its successor has
#     not registered yet. THE HANDOFF GAP IS REAL AND NORMALS WIN IT OTHERWISE:
#     stage N+1 only starts after stage N's process exits, and waiters are
#     spinning at $POLL. Measured without this clause, the chain used the lane
#     and was still admitted last — the two competitors took both turns during
#     the millisecond gap. So the marker holds the position across the gap, and
#     its expiry is what bounds the cost of a chain that has ended.
#
# Normal waiters consult this; resumers do not, or they would yield to
# themselves and to each other's markers.
resume_waiting() {
  local f now dl
  for f in "$RWAIT".*; do
    [ -e "$f" ] || continue
    if ! ( exec 4>"$f"; flock -n 4; ) 2>/dev/null; then return 0; fi
    rm -f "$f"
  done
  # $EPOCHSECONDS and a builtin `read` rather than `date` and `cut`: every normal
  # waiter runs this on every poll, so a fork here is a fork per waiter per
  # 200 ms across the whole queue.
  now="${EPOCHSECONDS:-0}"
  for f in "$MARK".*; do
    [ -e "$f" ] || continue
    dl=""; read -r dl _ < "$f" 2>/dev/null || true    # no trailing newline; see draw
    if [ "${dl:-0}" -ge "$now" ] 2>/dev/null; then return 0; fi
    rm -f "$f"                                   # lapsed: the chain ended here
  done
  return 1
}

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

# --- ONE build per worktree, enforced OUTSIDE the semaphore ---
# Two cargo invocations against the same worktree cannot proceed in parallel:
# cargo takes an exclusive lock on that worktree's `target/` directory, so the
# second blocks until the first finishes. That is correct cargo behaviour and
# not the bug. The bug is WHERE it blocks — if both have already been admitted,
# each holds a semaphore slot while one of them makes no progress at all, so the
# effective ceiling drops below SLOTS and the blocked one can burn its whole
# wall-clock budget waiting (AA-3261).
#
# It presents as "verifies are slow" rather than as a deadlock, which is why it
# was hard to see: nothing errors, nothing times out at the semaphore layer, and
# both runs look admitted and healthy.
#
# Serializing per worktree here, BEFORE a ticket is drawn, moves that wait
# outside the ticket queue: the second caller blocks holding no slot and drawing
# no ticket, so it neither consumes capacity nor takes a queue position it
# cannot use. Its self-healing is *conditional*, and the condition is the reason
# reap_escaped_orphans() exists: an flock is released when the last fd on its
# open file description closes, NOT when the pid that created it dies. A build
# child that escapes its scope carries that fd, so a "dead holder" in
# /proc/locks can still be a lock nothing legitimate is using. The wait below
# reaps first and only then blocks.
#
# Keyed by the resolved cwd, which is the worktree cargo will build in. Callers
# in different worktrees never contend.
WTKEY="$(pwd -P | cksum | tr -d ' \t-')"
exec 3>"$D/cargo-wt-$WTKEY.lock"
if ! flock -n 3; then
  # Before settling in to wait, rule out the wedged case: the lock may be held
  # by nothing but an escaped orphan's inherited fd, in which case waiting is
  # forever. reap_escaped_orphans() returns 0 when it actually killed something,
  # so retry the non-blocking acquire once before blocking.
  if reap_escaped_orphans && flock -n 3; then
    printf 'cargo-sem.sh: worktree lock was held by escaped orphans; reaped and acquired.\n' >&2
  else
    printf 'cargo-sem.sh: another build holds this worktree; waiting outside the queue.\n' >&2
    flock 3
  fi
fi

# --- which lane? read the chain marker the previous stage left ---
# Read under the ctl-lock together with the ticket draw, so the lane and the
# ticket cannot disagree. RESUMING=1 means this call continues a chain whose
# earlier stage already paid for a slot.
RESUMING=0; HOPS=0
exec 6>"$CTL"; flock 6
# An express build already outranks every lane, so it never also resumes —
# taking both presences would have it yield to itself.
if [ "$RESUME" = "1" ] && [ "$PRIO" != "1" ] && [ -f "$MARK.$WTKEY" ]; then
  # `read` reports failure at EOF even when it filled the variables, and this
  # file carries no trailing newline — so do not gate on its exit status.
  MDL=""; MHOPS=0
  read -r MDL MHOPS < "$MARK.$WTKEY" 2>/dev/null || true
  rm -f "$MARK.$WTKEY"
  if [ "${MDL:-0}" -ge "${EPOCHSECONDS:-0}" ] 2>/dev/null \
     && [ "${MHOPS:-0}" -le "$RESUME_MAX" ] 2>/dev/null; then
    RESUMING=1; HOPS="${MHOPS:-0}"
  fi
fi

# --- draw a ticket and register presence atomically under the ctl-lock ---
if [ "$RESUMING" = "1" ]; then
  T=$(rd "$RNEXT"); wr "$RNEXT" $((T + 1))
  exec 7>"$RWAIT.$T"; flock -n 7   # resume-lane presence
else
  T=$(rd "$NEXT"); wr "$NEXT" $((T + 1))
  exec 7>"$WAIT.$T"; flock -n 7   # own presence — self-flock always succeeds
fi
[ "$PRIO" = "1" ] && { exec 5>"$EXP.$T"; flock -n 5; }   # express presence
flock -u 6; exec 6>&-

# Optional trace for starvation debugging: records ticket order and,
# on admission, the wait. Off unless CARGO_SEM_DEBUG is set.
DBG="${CARGO_SEM_DEBUG:+$D/cargo-sem.debug.log}"
[ -n "$DBG" ] && printf '%s ticket=%s hops=%s t=%s args=%s\n' \
  "$([ "$RESUMING" = "1" ] && echo draw-resume || echo draw)" \
  "$T" "$HOPS" "$(date +%s.%N)" "$*" >> "$DBG"

# --- wait for the front of the queue AND a free slot ---
while true; do
  # Re-read the ceilings every pass. A waiter can sit here for hours while builds
  # around it finish and the memory window moves; without this it would keep
  # contending against its launch-time SLOTS, and as FIFO head it would hold the
  # low-water mark against everyone behind it (AA-5045).
  derive_limits

  # Each lane advances its own low-water mark over dead waiters. A resumer never
  # touches `serving`, so ordering among normal waiters is exactly as it was.
  exec 6>"$CTL"; flock 6
  if [ "$RESUMING" = "1" ]; then
    s=$(rd "$RSERV")
    while [ "$s" -lt "$T" ] && ! alive "$s" "$RWAIT"; do rm -f "$RWAIT.$s"; s=$((s + 1)); done
    wr "$RSERV" "$s"
  else
    s=$(rd "$SERV")
    while [ "$s" -lt "$T" ] && ! alive "$s"; do rm -f "$WAIT.$s"; s=$((s + 1)); done
    wr "$SERV" "$s"
  fi
  flock -u 6; exec 6>&-

  # Express lane: an express waiter must NOT also respect the FIFO gate below.
  # It registered its presence at draw time, so normal waiters are already
  # yielding to it; if it then waited its own turn behind them, both sides would
  # wait for each other and the queue would deadlock (observed, not theorised).
  # It contends for a slot directly and never advances `serving` — leaving the
  # normal ordering among normals exactly as it was. It still cannot preempt a
  # build already holding a slot: that would throw away real work.
  if [ "$PRIO" = "1" ]; then
    if acquire_slot; then
      exec 7>&-; rm -f "$WAIT.$T"                          # stop blocking normals
      exec 5>&-; rm -f "$EXP.$T"                           # stop normals yielding
      [ -n "$DBG" ] && printf 'admit-express ticket=%s slot=%s t=%s\n' "$T" "$SLOT_IDX" "$(date +%s.%N)" >> "$DBG"
      announce_admission
      break
    fi
    sleep "$POLL"; continue
  fi

  # Resume lane: FIFO among resumers by their own tickets, and it skips the
  # normal FIFO gate for the same reason express does — normals are already
  # yielding to it, so waiting its turn behind them would deadlock both sides.
  # It yields to express, which yields to nobody: the precedence is a total
  # order, so no two lanes can wait on each other.
  if [ "$RESUMING" = "1" ]; then
    if [ "$s" -lt "$T" ]; then sleep "$POLL"; continue; fi  # an earlier resumer is ahead
    if express_waiting; then sleep "$POLL"; continue; fi
    if acquire_slot; then
      exec 6>"$CTL"; flock 6
      [ "$(rd "$RSERV")" = "$T" ] && wr "$RSERV" $((T + 1))
      flock -u 6; exec 6>&-
      exec 7>&-; rm -f "$RWAIT.$T"                         # stop blocking normals
      [ -n "$DBG" ] && printf 'admit-resume ticket=%s hops=%s slot=%s t=%s\n' \
        "$T" "$HOPS" "$SLOT_IDX" "$(date +%s.%N)" >> "$DBG"
      announce_admission
      break
    fi
    sleep "$POLL"; continue
  fi

  if [ "$s" -lt "$T" ]; then sleep "$POLL"; continue; fi   # a live waiter is ahead

  # Express lane: a red `main` gates the whole pipeline, so the ci-fix build must
  # not queue behind verifies whose results are already known to be worthless.
  # Measured instance: the ci-fix sat 6th while all three slots were held by
  # verifies their own tasks had since moved to `blocked`. Yielding here bounds
  # the wait to the running builds rather than to the whole queue behind them.
  # It cannot preempt a build already holding a slot — that would throw away real
  # work — so an express build still waits for the first slot to free.
  # The resume lane is yielded to on the same terms and for the same shape of
  # reason: a half-finished verify's remaining stages are worth more than a
  # verify that has not started, and letting them finish is what drains the
  # queue rather than deepening it (AA-3129).
  if express_waiting || resume_waiting; then sleep "$POLL"; continue; fi

  if acquire_slot; then
    # Re-check the lanes now that the slot is actually held. The check above is
    # not atomic with the acquire — it globs two directories and forks a subshell
    # per candidate, and a slot can free during that — so on its own it loses the
    # handoff race intermittently (measured: 2 of 3 runs). Re-checking here is
    # decisive rather than tighter, because the ordering is guaranteed on the
    # other side: a stage that has more work writes its marker BEFORE dropping
    # its slot, so any slot we can win from a continuing chain already has that
    # chain's marker in place. Dropping the slot and looping costs one poll.
    if express_waiting || resume_waiting; then exec 9>&-; sleep "$POLL"; continue; fi
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

# Kill a build's whole process tree, deepest first.
#
# Walking /proc children is deliberate: the tree is
# time -> nice -> ionice -> env -> cargo -> N rustc -> sccache, and killing only
# the top leaves the compilers running — still holding memory and cores, which
# is the entire cost we are trying to reclaim. Killing by process GROUP is not
# an option either: this shell is not a group leader, so the group is the
# agent's whole session and `kill -- -PGID` would take the agent down with the
# build. Children first, parent last, so nothing re-parents mid-sweep.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

# --- stop building for a task nobody is waiting on ---
# A verify moved to `blocked` (branch conflicts with the base) has a worthless
# result, but its build holds a slot until it finishes on its own, delaying
# every build queued behind it.
#
# The server cannot do this itself — it knows this pid but not the tree below
# it, and killing by group would hit the agent's session. So cancellation is a
# flag the server sets and this watcher reads, and the teardown happens here
# where the process tree is known.
#
# Poll interval is deliberately slow. A build runs for tens of minutes to hours;
# reclaiming a slot 30s later than theoretically possible costs nothing, and a
# tight loop against the API for every concurrent build would cost more than the
# slot is worth.
watch_for_cancel() {
  local build_pid="$1" status
  [ -n "$DETACHED_RUN_ID" ] && [ -n "${PAPERCLIP_API_URL:-}" ] || return 0
  while kill -0 "$build_pid" 2>/dev/null; do
    sleep "${CARGO_SEM_CANCEL_POLL:-30}"
    status=$(curl -fsS --max-time 5 \
      ${PAPERCLIP_API_KEY:+-H "Authorization: Bearer $PAPERCLIP_API_KEY"} \
      "$PAPERCLIP_API_URL/api/heartbeat-runs/$DETACHED_RUN_ID" 2>/dev/null |
      sed -n 's/.*"status":"\([a-z_]*\)".*/\1/p')
    if [ "$status" = "cancelled" ]; then
      printf 'cargo-sem.sh: build cancelled server-side; tearing down pid %s\n' "$build_pid" >&2
      kill_tree "$build_pid"
      return 0
    fi
  done
}

open_detached_run "$@"
trap 'close_detached_run "${rc:-143}"' EXIT

# The build runs as a background child so this shell stays free to watch for
# cancellation. fd 9 (the slot lock) is inherited and also still held here, so
# the slot is released only when BOTH have exited — the FD LIFETIME contract in
# the header is unchanged.
run "$@" & BUILD_PID=$!
watch_for_cancel "$BUILD_PID" &
WATCH_PID=$!

wait "$BUILD_PID"; rc=$?
kill "$WATCH_PID" 2>/dev/null || true
close_detached_run "$rc"

# --- leave a chain marker for this worktree's next stage (AA-3129) ---
# BEFORE the slot lock is dropped, and that ordering is load-bearing: waiters
# are spinning at $POLL, so a marker written after the release loses the gap to
# whoever is polling. Measured with the two swapped, the chain used the lane and
# was still overtaken. Holding the slot while writing costs nothing — the slot
# is busy either way, and the marker only makes normal waiters yield.
#
# A failed stage ends the caller's `&&` chain, so there is nothing to resume; a
# chain that has spent its hand-offs queues normally from here on.
if [ "$RESUME" = "1" ] && [ "$rc" -eq 0 ] && [ "$HOPS" -lt "$RESUME_MAX" ] 2>/dev/null; then
  printf '%s %s' "$(( ${EPOCHSECONDS:-0} + GRACE ))" "$((HOPS + 1))" > "$MARK.$WTKEY"
else
  rm -f "$MARK.$WTKEY"
fi
exec 9>&-
exit "$rc"
