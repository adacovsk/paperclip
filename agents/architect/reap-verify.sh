#!/usr/bin/env bash
# Reap a detached verify build whose result nobody will consume (AA-3253).
#
# WHY THIS IS A SCRIPT AND NOT A PARAGRAPH. The reap procedure was documented in
# exactly one place — Coordinator §Worktree teardown, for the post-merge case —
# with an explicit warning not to lift it elsewhere. So every other exit that
# should reap either didn't, or was hand-improvised per fire. Five separately
# measured instances, over five weeks, all of the same shape: a build holding a
# `cargo-sem.sh` slot (or a FIFO position ahead of one) for a task that could not
# consume the result. One held a slot 1h40m while 10 landable verifies queued
# behind 3 slots; another compiled a worktree that had already been deleted;
# three at once were building branches whose PRs were already open, while the
# ci-fix for a red `main` waited. One implementation, called from every exit,
# is the only thing that makes the rule hold at all of them.
#
# THE SAFETY ARGUMENT — the reap turns on whether the TASK STILL WANTS A RESULT,
# never on process liveness. A live wrapper whose dispatching run has died is NOT
# an orphan: that is the normal decoupled-land pattern, where the run hits its 2h
# watchdog while the detached build legitimately continues (observed alive at
# 3h09m) and still writes its sentinel. Killing on liveness alone destroys live
# work. Each reason below is admitted only because the task provably cannot
# consume the result, and the self-checking ones are re-verified here rather than
# trusted from the caller.
#
# Usage:  reap-verify.sh <task-id> <reason> [--dry-run]
#         reap-verify.sh --list                 # what is live, and what wants it
#
# Exit: 0 reaped (or nothing to reap), 2 bad usage, 3 reason not proven.
set -u

VERIFY_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
PROJECT="${PAPERCLIP_PROJECT:-$HOME/code/bevy-rpg}"

# Written into `<id>.exit` BEFORE the kill. The wrapper's own trap is
# `_sentinel(){ [ -f "$S/<id>.exit" ] || echo 99 > "$S/<id>.exit"; }` — it only
# writes when the file is ABSENT, so pre-writing our code makes the trap a no-op
# and 100 survives the signal.
#
# This ordering is the whole point. Without it the reap is worse than useless:
# the trap writes 99, `99` means "wrapper was signalled — INCONCLUSIVE, relaunch"
# in the Architect's sentinel state machine, and the next wake starts the build
# again. The reap would then cost a build and free nothing. Same for the launch
# block's `signal: (9|15)` remap to 137, which also means relaunch.
REAPED_CODE=100

usage() { sed -n '2,30p' "$0" >&2; exit 2; }

# --- reasons ---------------------------------------------------------------
# Each is a claim that the task cannot consume the result. Self-checking ones are
# re-proven here; the rest are the caller's to establish, because they are facts
# about Paperclip state this script has no credentials to read.
#
#   pr-merged        the PR for task/<id> merged. Nothing to verify. (caller)
#   verify-done      the verify subtask is done/cancelled, so the stage that
#                    would read the sentinel has already finished. (caller)
#   parent-cancelled the parent task is cancelled; abandoned. (caller)
#   worktree-gone    the worktree is deleted — SELF-CHECKED below. The build
#                    survives with cwd marked `(deleted)` and compiles a tree
#                    that no longer exists.
#   unlandable       the branch cannot merge into current origin/main — SELF-
#                    CHECKED below, and deliberately so: see the note under
#                    `blocked` in the Coordinator instructions. The assumption
#                    "blocked implies conflicted" was measured FALSE (two blocked
#                    tasks, both merging clean), so this reason must be proven per
#                    invocation, never inferred from a status.
REASONS="pr-merged verify-done parent-cancelled worktree-gone unlandable"

# Every live build, labelled by how it was launched. Two things it must not
# conflate: a build with no systemd unit is a bare-setsid fallback that only the
# /proc walk can reap, and a build whose directory is not a `task/AA-*` worktree
# is off the pipeline's books entirely (an operator worktree, or the main
# checkout). The latter is NOT reapable by this script — it has no task, so no
# reason can be proven about it — and it is listed only because it consumes the
# same slots and is otherwise invisible to every census keyed on `verifyrun-`.
list_live() {
  local unit id cwd
  {
    for unit in $(systemctl --user list-units --no-legend --plain 'verifyrun-*' 2>/dev/null | awk '{print $1}'); do
      printf '%s\tunit=%s\n' "$(printf '%s' "$unit" | sed -E 's/^verifyrun-(.*)\.(scope|service)$/\1/')" "$unit"
    done
    for pid in $(pgrep -f 'cargo-sem\.sh' 2>/dev/null); do
      cwd="$(readlink /proc/"$pid"/cwd 2>/dev/null)" || continue
      id="$(basename "${cwd% (deleted)}" 2>/dev/null)"
      [ -n "$id" ] && printf '%s\tproc\n' "$id"
    done
  } | sort -u | awk -F'\t' '
    { seen[$1] = seen[$1] " " $2 }
    END {
      for (id in seen) {
        tag = (id ~ /^AA-[0-9]+$/) ? "task" : "OFF-BOOKS (no task; not reapable here)"
        printf "%-12s %-28s%s\n", id, tag, seen[id]
      }
    }' | sort
}

[ $# -ge 1 ] || usage
if [ "$1" = "--list" ]; then list_live | sort -u; exit 0; fi
[ $# -ge 2 ] || usage

ID="$1"; REASON="$2"; DRY=""
[ "${3:-}" = "--dry-run" ] && DRY=1
case " $REASONS " in *" $REASON "*) ;; *)
  printf 'reap-verify: unknown reason %s (want one of: %s)\n' "$REASON" "$REASONS" >&2; exit 2 ;;
esac

W="$PROJECT/.paperclip/worktrees/$ID"

# --- prove the self-checking reasons ---------------------------------------
case "$REASON" in
  worktree-gone)
    if [ -d "$W" ]; then
      printf 'reap-verify: REFUSED — %s still exists, so "worktree-gone" is not true.\n' "$W" >&2
      exit 3
    fi ;;
  unlandable)
    if [ ! -d "$W" ]; then
      printf 'reap-verify: REFUSED — no worktree at %s; cannot prove the branch is unlandable (use worktree-gone).\n' "$W" >&2
      exit 3
    fi
    git -C "$PROJECT" fetch -q origin main 2>/dev/null || true
    sha="$(git -C "$W" rev-parse HEAD 2>/dev/null)" || { printf 'reap-verify: REFUSED — cannot read HEAD in %s.\n' "$W" >&2; exit 3; }
    if git -C "$PROJECT" merge-tree --write-tree origin/main "$sha" >/dev/null 2>&1; then
      printf 'reap-verify: REFUSED — task/%s (%s) merges CLEAN into origin/main, so its build result is still usable.\n' "$ID" "${sha:0:8}" >&2
      printf '            A blocked task is not automatically an unlandable one. Leave the build alone.\n' >&2
      exit 3
    fi ;;
esac

# --- write the sentinel FIRST, then kill -----------------------------------
if [ -n "$DRY" ]; then
  printf 'reap-verify: DRY RUN — would write %s to %s/%s.exit and stop the build for %s (%s)\n' \
    "$REAPED_CODE" "$VERIFY_DIR" "$ID" "$ID" "$REASON"
  exit 0
fi

mkdir -p "$VERIFY_DIR"
printf '%s\n' "$REAPED_CODE" > "$VERIFY_DIR/$ID.exit"
printf 'reaped: %s (build stopped deliberately; the task could not consume the result)\n' "$REASON" \
  >> "$VERIFY_DIR/$ID.log" 2>/dev/null || true

stopped=""
# A transient scope is an exact, atomic handle on the whole chain: stopping the
# unit kills its cgroup, so no descendant can be missed and nothing else can be
# hit by accident. Prefer it over any process walk.
for unit in "verifyrun-$ID.scope" "verifyrun-$ID.service"; do
  if systemctl --user --quiet is-active "$unit" 2>/dev/null; then
    systemctl --user stop "$unit" 2>/dev/null && stopped="$unit"
    break
  fi
done

if [ -z "$stopped" ]; then
  # Bare-setsid fallback (no user bus at launch): enumerate ACTUAL slot holders
  # and keep the ones living in this worktree, then kill the process GROUP.
  #
  # Do NOT substitute `ps aux | grep <worktree-path>`. It matches on cmdline:
  # cargo-sem.sh embeds the path, but its cargo / clippy-driver / rustc
  # descendants inherit the directory via `cd` and carry relative paths, so they
  # never match. And once the directory is gone the kernel marks the cwd
  # `(deleted)`, so even a cwd grep on the live path stops matching — hence the
  # suffix strip below. The slot lock plus /proc is the probe that sees them.
  for pid in $(fuser /tmp/cargo-slot-*.lock 2>/dev/null); do
    cwd="$(readlink /proc/"$pid"/cwd 2>/dev/null)" || continue
    case "${cwd% (deleted)}" in "$W"|"$W"/*)
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
      [ -n "$pgid" ] && kill -TERM "-$pgid" 2>/dev/null && stopped="pgid $pgid" ;;
    esac
  done
fi

if [ -n "$stopped" ]; then
  printf 'reap-verify: %s reaped (%s) via %s; sentinel %s written.\n' "$ID" "$REASON" "$stopped" "$REAPED_CODE"
else
  printf 'reap-verify: %s had no live build; sentinel %s written so a stale wake cannot relaunch it.\n' "$ID" "$REAPED_CODE"
fi
