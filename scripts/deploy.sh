#!/usr/bin/env bash
# Deploy the live checkout: bring it to origin, then do only what the change needs.
#
# The server runs without `tsx watch`, so pulling this checkout changes nothing
# that is running. It used to: any pull that touched a server file restarted the
# server, and a restart kills every in-flight agent run. Six restarts in one day
# came from pulls that were not meant as deploys. This script is the one place a
# restart is decided.
#
#   agents/**, docs            -> nothing to do; the pipeline's scripts are read
#                                 from this checkout each time they run
#   pnpm-lock.yaml             -> pnpm install --frozen-lockfile
#   ui/** or a package it uses -> rebuild the UI (served from ui/dist)
#   server/** or packages/**   -> restart the server; migrations apply on boot
#
# "Changed" means since that step last ran, recorded per step under
# .git/paperclip-deploy/, not since this checkout's HEAD: a checkout pulled by
# anything else still deploys what the pull brought in.
#
# Usage: deploy.sh [--wait MINUTES] [--restart] [--dry-run]
#   --wait MINUTES  before restarting, wait up to MINUTES for no agent run to be
#                   in flight. A run a restart kills is retried, but the retry
#                   re-pays its whole context load.
#   --restart       restart even when the change does not need one
#   --dry-run       say what would be done and do none of it
# Env: PAPERCLIP_UNIT (default paperclip.service), PAPERCLIP_API_URL
#      (default http://127.0.0.1:3100), PAPERCLIP_DEPLOY_BRANCH (default master)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="${PAPERCLIP_UNIT:-paperclip.service}"
API="${PAPERCLIP_API_URL:-http://127.0.0.1:3100}"
BRANCH="${PAPERCLIP_DEPLOY_BRANCH:-master}"
WAIT_MINUTES=0
FORCE_RESTART=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT_MINUTES="${2:?--wait needs a number of minutes}"; shift 2 ;;
    --restart) FORCE_RESTART=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "deploy: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$WAIT_MINUTES" in ''|*[!0-9]*) echo "deploy: --wait takes whole minutes" >&2; exit 2 ;; esac

say() { printf 'deploy: %s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then say "would run: $*"; else "$@"; fi; }

cd "$ROOT"
current="$(git branch --show-current)"
if [ "$current" != "$BRANCH" ]; then
  echo "deploy: this checkout is on '$current', not '$BRANCH'; it is not the live checkout" >&2
  exit 1
fi
# A tracked file edited in place would be served, or would block the pull.
# Untracked files are left alone: agents leave working files in this tree.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "deploy: tracked files are modified here; commit or restore them first:" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

before="$(git rev-parse HEAD)"
git fetch --quiet origin "$BRANCH"
after="$(git rev-parse "origin/$BRANCH")"
if [ "$before" = "$after" ]; then
  say "already at ${before:0:9}"
  changed=""
else
  say "${before:0:9} -> ${after:0:9}, $(git diff --name-only "$before" "$after" | wc -l) file(s)"
  run git merge --quiet --ff-only "origin/$BRANCH"
fi

# Each step is decided against the commit that step last ran at, never against
# this checkout's HEAD before the pull. Anything can move this checkout (an
# operator's `git pull`, another session's merge) without deploying it, and a
# HEAD-to-origin diff then reads "nothing new" while the server, the UI build
# or node_modules is still on older code. That happened twice in one day: once
# with a schema migration left unapplied. A missing or unreadable stamp means
# the state is unknown, so the step runs.
STAMPS="$(git rev-parse --git-dir)/paperclip-deploy"
stamp_of() { cat "$STAMPS/$1" 2>/dev/null || true; }
stamp() { [ "$DRY" = 1 ] || { mkdir -p "$STAMPS" && echo "$after" > "$STAMPS/$1"; }; }
# needs <step> <pattern>: true when the step must run to bring its output to $after.
needs() {
  local at; at="$(stamp_of "$1")"
  [ "$at" = "$after" ] && return 1
  if [ -z "$at" ] || ! git cat-file -e "$at^{commit}" 2>/dev/null; then
    say "$1: no record of the commit it last ran at"
    return 0
  fi
  if git diff --name-only "$at" "$after" | grep -qE "$2"; then
    [ "$at" = "$before" ] || say "$1: last ran at ${at:0:9}, behind this checkout"
    return 0
  fi
  stamp "$1"  # nothing it depends on changed since: its output is current
  return 1
}

if needs install '^pnpm-lock\.yaml$'; then
  say "dependencies changed"
  run pnpm install --frozen-lockfile
  stamp install
fi

if needs ui '^(ui/|packages/(shared|adapter-utils|adapters)/)'; then
  say "rebuilding the UI"
  run pnpm --filter @paperclipai/ui build
  stamp ui
fi

restart=$FORCE_RESTART
if needs server '^(server/|packages/|package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$)'; then
  restart=1
fi
if [ "$restart" = 0 ]; then
  say "nothing running needs a restart"
  exit 0
fi

in_flight() {
  curl -fsS --max-time 10 "$API/api/live-runs" 2>/dev/null \
    | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r.get("status") == "running"))' 2>/dev/null \
    || echo "?"
}

deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while :; do
  n="$(in_flight)"
  [ "$n" = 0 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    if [ "$n" = "?" ]; then say "the server did not answer; restarting it"
    else say "$n agent run(s) in flight will be killed and retried"; fi
    break
  fi
  say "$n agent run(s) in flight; waiting"
  sleep 20
done

say "restarting $UNIT"
run systemctl --user restart "$UNIT"
[ "$DRY" = 1 ] && exit 0

for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "$API/api/health" >/dev/null 2>&1; then
    stamp server
    say "server is up at $(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 3
done
echo "deploy: the server did not come back within 3 minutes; see: journalctl --user -u $UNIT -n 100" >&2
exit 1
