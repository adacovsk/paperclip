#!/usr/bin/env bash
# Launch a task's verify build on this machine, detached, and return at once.
#
# WHY A SCRIPT. The chain used to live only in the Architect's §Landing block as
# a single-quoted string a model pasted, so only a model could launch a local
# build. With the cloud lane closed that is every build: the Dispatcher launched
# a Verify's first build itself only while the lane was open, and a refused
# offload or a refused freshness re-verify woke the Architect just to paste the
# chain. relaunch-verify.sh now falls back to this script, and the Architect's
# instructions call it, so there is one copy of the chain and both lanes need no
# model to start a build.
#
# The chain is unchanged: it writes `<task>.pid`, rebases (or merges) onto
# origin/main, records `<task>.base` and the built `<task>.head`, runs clippy and
# `cargo test --lib` under cargo-sem.sh, writes `<task>.exit` and fires the
# sentinel callback. Its codes are the Architect's sentinel state machine:
# 96 env broken, 97 worktree missing, 98 base not current, 99 signalled,
# 137 OOM-killed, else cargo's own.
#
# THE TRAP HANDLERS ARE FUNCTIONS ON PURPOSE. An inline `trap '...' EXIT` inside
# a single-quoted body needs nested quoting that breaks as soon as the body is
# copied anywhere the outer quotes are absent (`trap: -f: invalid signal
# specification`, and a sentinel for a run that never started). Keep the handler
# bodies quote-free.
#
# `setsid` detaches the session, not the cgroup: the chain would stay in
# paperclip.service and die with a server restart. A transient user scope
# reparents it out; bare setsid is only the fallback where there is no user bus.
#
# Usage:  local-verify.sh <task-id> <verify-task-id> [--express]
#         --express  the freshness re-verify's express lane (CARGO_SEM_PRIORITY=1)
# Exit:   0  launched; 1 not launched, and the last line of output says why
# Env:    PAPERCLIP_PROJECT (required), XDG_CACHE_HOME,
#         LOCAL_VERIFY_SEM / LOCAL_VERIFY_CALLBACK / LOCAL_VERIFY_SCOPE (test seams;
#         LOCAL_VERIFY_SCOPE=0 forces bare setsid), LOCAL_VERIFY_PRINT=1 prints the
#         chain instead of launching it
set -uo pipefail

task="${1:?task id}"; verify="${2:?verify task id}"; express="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}"
S="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify"

say() { echo "local-verify $task: $*"; }
# The ids are spliced into the chain's text, and into a unit name.
for id in "$task" "$verify"; do
  [[ "$id" =~ ^[A-Za-z]+-[0-9]+$ ]] || { say "refusing id '$id'"; exit 1; }
done
[ -z "$express" ] || [ "$express" = "--express" ] || { say "unknown option $express"; exit 1; }
[ ! -e "$S/$task.exit" ] || { say "a sentinel is already present"; exit 1; }
! "$HERE/verify-census.sh" "$task" >/dev/null 2>&1 || { say "a local build is already running"; exit 1; }

SEM="${LOCAL_VERIFY_SEM:-$HERE/cargo-sem.sh}"
CALLBACK="${LOCAL_VERIFY_CALLBACK:-$HERE/sentinel-callback.sh}"
mkdir -p "$S"

BODY='S="'"$S"'"; mkdir -p "$S"; echo verifyrun-@TASK@; echo $$ > "$S/@TASK@.pid"; rm -f "$S/@TASK@.exit" "$S/@TASK@.base-red"; _sentinel(){ [ -f "$S/@TASK@.exit" ] || echo 99 > "$S/@TASK@.exit"; }; _killed(){ echo "KILLED: wrapper took a signal before cargo reported — inconclusive, relaunch"; _sentinel; exit 99; }; trap _sentinel EXIT; trap _killed HUP INT TERM; A="@VERIFY@"; [ -n "$A" ] && [ "$A" != "@TASK@" ] && for x in pid exit base log; do ln -sfn "$S/@TASK@.$x" "$S/$A.$x"; done; . "$HOME/.cargo/env" 2>/dev/null || true; export PATH="$HOME/.local/bin:$PATH"; unset CARGO_TARGET_DIR; command -v cargo >/dev/null && command -v sccache >/dev/null || { echo "ENV BROKEN: cargo/sccache still not on PATH after bootstrap — this is NOT a build failure, do not edit Rust; escalate to operator"; echo 96 > "$S/@TASK@.exit"; exit 96; }; cd "@PROJECT@/.paperclip/worktrees/@TASK@" || { echo "ENV BROKEN: worktree missing or PAPERCLIP_PROJECT unset"; echo 97 > "$S/@TASK@.exit"; exit 97; }; git fetch -q origin main || { echo "STALE BASE: git fetch origin main failed — cannot confirm the build sits on current main"; echo 98 > "$S/@TASK@.exit"; exit 98; }; { ! git ls-remote --exit-code --heads origin "task/@TASK@" >/dev/null 2>&1 && git rebase origin/main >/dev/null 2>&1; } || { git rebase --abort >/dev/null 2>&1; git merge --no-edit origin/main >/dev/null 2>&1 || { git merge --abort >/dev/null 2>&1; echo "STALE BASE: neither rebase nor merge onto current origin/main succeeds — operator must resolve"; echo 98 > "$S/@TASK@.exit"; exit 98; }; echo "NOTE: branch already on origin, or the rebase replay conflicted; verifying on a merge commit"; }; git rev-parse origin/main > "$S/@TASK@.base"; git rev-parse HEAD > "$S/@TASK@.head"; sccache --start-server >/dev/null 2>&1 || true; SEM="@SEM@"; L="$S/@TASK@.log"; LC0=$(wc -l < "$L" 2>/dev/null || echo 0); "$SEM" env CARGO_INCREMENTAL=0 cargo clippy --all-targets -- -D warnings -A dead-code -A unused-imports && CARGO_SEM_CGU_DIV=2 "$SEM" env CARGO_INCREMENTAL=0 cargo test --lib; rc=$?; if [ "$rc" -ne 0 ] && tail -n +$((LC0+1)) "$L" 2>/dev/null | grep -qE "signal: (9|15)"; then rc=137; fi; echo $rc > "$S/@TASK@.exit"; "@CALLBACK@" "@VERIFY@"'
BODY="${BODY//@TASK@/$task}"
BODY="${BODY//@VERIFY@/$verify}"
BODY="${BODY//@PROJECT@/$PAPERCLIP_PROJECT}"
BODY="${BODY//@SEM@/$SEM}"
BODY="${BODY//@CALLBACK@/$CALLBACK}"

[ "${LOCAL_VERIFY_PRINT:-0}" = 0 ] || { printf '%s\n' "$BODY"; exit 0; }
if [ -n "$express" ]; then export CARGO_SEM_PRIORITY=1; else unset CARGO_SEM_PRIORITY; fi
if [ "${LOCAL_VERIFY_SCOPE:-1}" != 0 ] && systemd-run --user --scope --collect --quiet true >/dev/null 2>&1; then
  systemd-run --user --scope --collect --quiet --unit="verifyrun-$task" \
    --setenv=PAPERCLIP_API_URL --setenv=PAPERCLIP_API_KEY --setenv=PAPERCLIP_AGENT_ID \
    ${CARGO_SEM_PRIORITY:+--setenv=CARGO_SEM_PRIORITY} \
    setsid bash -c "$BODY" >> "$S/$task.log" 2>&1 < /dev/null &
else
  setsid bash -c "$BODY" >> "$S/$task.log" 2>&1 < /dev/null &
fi
say "launched locally${express:+ (express lane)}"
