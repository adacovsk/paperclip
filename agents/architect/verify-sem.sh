#!/usr/bin/env bash
# Run a command holding one of the machine's verify slots, at lowered priority.
#
#   verify-sem.sh pixi run -e dev verify [--head <sha>]
#
# WHY THIS EXISTS. The project's gate bounds itself: its script takes one of
# VERIFY_SEM_SLOTS flock slots before doing any work. But a task worktree runs
# the copy of that script its branch forked with, and a branch that forked
# before the bound existed runs unbounded. Seventeen gate runs at once, each
# parallel inside, put the box at load 100 on 8 threads; the task server
# answered in 25 seconds and the Dispatcher's sweep timed out, which stalled
# the queue those runs were gating. The call sites that start a gate for a task
# worktree are shared, so wrapping them bounds every such run whatever script
# the worktree carries.
#
# ONE COUNT PER POOL. The slot files and the VERIFY_SEM_SLOTS / VERIFY_SEM_DIR
# names are the project script's own, so a run started here and a run started
# by a push hook draw on the same slots. VERIFY_SEM_HELD is exported once a
# slot is held, which is how a script that does take slots knows not to queue
# for a second one behind its own parent. Landings set VERIFY_SEM_DIR to a
# pool of their own (land.sh): self-checks fill the shared pool, and a merge
# waiting behind them is the stall the bound was never meant to cause.
#
# The lock is an flock on fd 9, held by this shell while the command runs as
# its child, so the kernel frees the slot when this process dies. Waiters poll
# with jitter and are not served in arrival order; a gate run lasts minutes, so
# losing a round costs seconds. VERIFY_SEM_SLOTS=0 disables the wait, and a box
# without flock runs unbounded rather than failing the gate.
#
# The body is one function called on the last line. bash reads a script as it
# runs it, and this one can sit in its wait loop for minutes; a pull that
# rewrote the file under it would resume the loop inside the new bytes. A
# function is read whole before it runs.
set -uo pipefail

main() {
  local slots="${VERIFY_SEM_SLOTS:-2}" dir="${VERIFY_SEM_DIR:-/tmp/verify-sem-$(id -u)}" waited=0 nap i held=0
  [ "$#" -gt 0 ] || { echo "usage: ${0##*/} <command> [args...]" >&2; return 2; }
  renice -n 10 -p $$ >/dev/null 2>&1 || true
  if [ -z "${VERIFY_SEM_HELD:-}" ] && [ "$slots" -gt 0 ] 2>/dev/null \
     && command -v flock >/dev/null 2>&1 && mkdir -p "$dir" 2>/dev/null; then
    while [ "$held" = 0 ]; do
      for ((i = 1; i <= slots; i++)); do
        exec 9>"$dir/slot-$i.lock" || break 2
        if flock -n 9; then held=1; break; fi
        exec 9>&-
      done
      [ "$held" = 1 ] && break
      [ "$waited" -eq 0 ] && echo "verify-sem: $slots gate run(s) already going; waiting for a slot." >&2
      nap=$((1 + RANDOM % 3))
      sleep "$nap"
      waited=$((waited + nap))
    done
    [ "$waited" -gt 0 ] && echo "verify-sem: got a slot after ${waited}s." >&2
    export VERIFY_SEM_HELD=1
  fi
  "$@"
}

main "$@"; exit $?
