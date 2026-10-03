#!/usr/bin/env bash
# Move local verify builds that are still QUEUED (waiting for a cargo slot,
# nothing compiling yet) onto the cloud lane while it is open.
#
# Usage:  migrate-queued-verify.sh [--dry-run] [<task-id> ...]
#         With no ids, every live `verifyrun-*` scope is considered.
# Run with the Architect's environment: ARCHITECT_CLOUD_LANE=1 and the same
# CLOUD_PACE_* settings, because the offload re-checks both, and
# PAPERCLIP_API_URL plus PAPERCLIP_AGENT_ID (the Architect's id), because the cloud
# watcher it starts sends the "verify finished" wake with them. Without them the
# watcher skips the wake silently: the verdict lands and nothing reads it. That
# happened to the first six builds this script moved, so it now refuses to start.
#
# WHY. A verify is routed once, at launch. A build launched while the cloud lane
# was closed queues for a local slot and stays queued after the lane opens. The
# semaphore sizes itself from free memory, so on a busy desktop that is ONE slot,
# and each verify chains four cargo steps. Thirty-three builds were measured
# queued at once, the oldest for 36 hours, with the lane open the whole time.
#
# WHAT IS SAFE TO MOVE. Only a build with no compiler in its scope: no rustc,
# cargo or clippy-driver. A queued wrapper is bash, flock and sleep, so stopping it
# discards no compile work. One that is compiling is left alone, because the cloud
# would start that build over. The task still wants the result, which is why this
# is not a `reap-verify.sh` reason: a reap says the result is unwanted.
#
# ORDER. The wrapper's EXIT trap writes 99 ("inconclusive, relaunch") when
# `<id>.exit` is absent, so the sentinel is written first and the trap becomes a
# no-op. `cloud-verify.sh offload` then clears it and starts the cloud watch.
# If the offload refuses (the lane closed in between, or the tree is dirty), the
# sentinel is removed, so the Architect's next wake finds "absent, no build"
# and relaunches locally. A move can delay a verify; it cannot strand one.
#
# STOP AT THE FIRST REFUSAL, AND SPACE THE MOVES. Each offload re-reads account
# usage. Thirty-nine back-to-back moves drew HTTP 429 from the usage endpoint after
# the fourth, every later offload refused, and each of those builds had already
# been stopped: thirty-five queued verifies lost their place and had to be
# re-dispatched by hand. A refusal now ends the run with every remaining build
# still queued, and MIGRATE_INTERVAL seconds separate the moves.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"
PROJECT="${PAPERCLIP_PROJECT:-$HOME/code/bevy-rpg}"
CLOUD_VERIFY="${MIGRATE_CLOUD_VERIFY:-$HERE/cloud-verify.sh}"
PACE="${MIGRATE_PACE:-python3 $HERE/cloud-pace.py}"
CGROUP_ROOT="${MIGRATE_CGROUP_ROOT:-/sys/fs/cgroup}"
PARKED_CODE=100
INTERVAL="${MIGRATE_INTERVAL:-20}"

DRY=""
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

units_for() {  # every live scope of one task (relaunches carry a numeric suffix)
  systemctl --user list-units --no-legend --plain --state=running 'verifyrun-*' 2>/dev/null \
    | awk '{print $1}' | grep -E "^verifyrun-$1(-[0-9]+)?\.(scope|service)$"
}

compiling() {  # does any process in the unit's cgroup run a compiler?
  local cg pid comm
  cg="$(systemctl --user show "$1" -p ControlGroup --value 2>/dev/null)"
  [ -n "$cg" ] || return 0   # cannot see inside: treat as compiling, leave it
  for pid in $(cat "$CGROUP_ROOT$cg/cgroup.procs" 2>/dev/null); do
    comm="$(cat /proc/"$pid"/comm 2>/dev/null)"
    case "$comm" in rustc|cargo|clippy-driver|build-script-*) return 0 ;; esac
  done
  return 1
}

verify_task_for() {  # the Verify subtask the wrapper wakes, from its `A="..."`
  local pid
  pid="$(cat "$VERIFY_DIR/$1.pid" 2>/dev/null)"
  tr '\0' ' ' < /proc/"$pid"/cmdline 2>/dev/null | grep -oE 'A="AA-[0-9]+"' | head -1 \
    | grep -oE 'AA-[0-9]+' || printf '%s\n' "$1"
}

if [ -z "${PAPERCLIP_API_URL:-}" ] || [ -z "${PAPERCLIP_AGENT_ID:-}" ]; then
  echo "migrate-queued-verify: PAPERCLIP_API_URL and PAPERCLIP_AGENT_ID must name the Architect — a moved build would finish without waking it; nothing moved" >&2
  exit 2
fi

if [ "$(${PACE} 2>/dev/null | head -1)" != "1" ]; then
  echo "migrate-queued-verify: cloud lane closed — nothing moved"
  exit 0
fi

if [ $# -eq 0 ]; then
  set -- $(systemctl --user list-units --no-legend --plain --state=running 'verifyrun-*' 2>/dev/null \
    | awk '{print $1}' | sed -E 's/^verifyrun-(AA-[0-9]+).*/\1/' | sort -u)
fi

moved=0; kept=0
for id in "$@"; do
  units="$(units_for "$id")"
  if [ -z "$units" ]; then echo "$id: no live build"; continue; fi
  busy=""
  for unit in $units; do compiling "$unit" && busy="$unit"; done
  if [ -n "$busy" ]; then echo "$id: compiling in $busy — left local"; kept=$((kept + 1)); continue; fi
  wt="$PROJECT/.paperclip/worktrees/$id"
  if [ ! -d "$wt" ]; then echo "$id: no worktree — left alone"; kept=$((kept + 1)); continue; fi
  vt="$(verify_task_for "$id")"
  if [ -n "$DRY" ]; then echo "$id: would move to the cloud lane (wakes $vt)"; continue; fi

  [ "$moved" -gt 0 ] && sleep "$INTERVAL"
  printf '%s\n' "$PARKED_CODE" > "$VERIFY_DIR/$id.exit"
  for unit in $units; do systemctl --user stop "$unit" 2>/dev/null; done
  echo "migrated: queued local build stopped for the cloud lane" >> "$VERIFY_DIR/$id.log" 2>/dev/null || true
  if (cd "$wt" && "$CLOUD_VERIFY" offload "$id" "task/$id" "$vt"); then
    moved=$((moved + 1))
  else
    rm -f "$VERIFY_DIR/$id.exit"
    echo "$id: offload refused — sentinel cleared, the Architect relaunches it locally"
    echo "migrate-queued-verify: stopping at the first refusal; every remaining build stays queued"
    kept=$((kept + 1))
    break
  fi
done
echo "migrate-queued-verify: moved $moved, left $kept"
