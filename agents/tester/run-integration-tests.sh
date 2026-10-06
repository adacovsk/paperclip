#!/usr/bin/env bash
# Build and run every test target against current origin/main, record the
# failures as JSON, then wake the Tester to report them.
#
# Runs DETACHED. The Tester launches it and ends its run; this script wakes the
# Tester again when the result is on disk. A run that watched the build instead
# would pay a full context read per poll for 30-60 minutes, and run cost tracks
# turns x context, not wall time.
#
# It builds a dedicated detached worktree of origin/main, never a task branch:
# the point is a verdict on `main`, which every task branch inherits.
#
# Usage:  run-integration-tests.sh <issue-id-to-wake-on>    (the routine issue's UUID)
#
# State, in ${XDG_CACHE_HOME:-~/.cache}/paperclip-tester/:
#   pid          this run, while it is alive
#   log          cargo's full output
#   result.json  written last; its presence is what the Tester reads
#   exit         cargo's exit status (137 = killed, 96-99 = environment, see below)
#   last-green   the newest origin/main SHA on which every test passed
set -u

WAKE_ISSUE="${1:?usage: run-integration-tests.sh <issue-id>}"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-tester"
PROJECT="${PAPERCLIP_PROJECT:-$HOME/code/bevy-rpg}"
WT="${TESTER_WORKTREE:-$HOME/code/bevy-rpg-tester}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SEM="$HERE/../architect/cargo-sem.sh"
mkdir -p "$STATE"

if [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; then
  echo "already running (pid $(cat "$STATE/pid"))"
  exit 0
fi
echo $$ > "$STATE/pid"
rm -f "$STATE/result.json" "$STATE/exit"
: > "$STATE/log"

wake() {
  [ -n "${PAPERCLIP_API_URL:-}" ] && [ -n "${PAPERCLIP_AGENT_ID:-}" ] || return 0
  curl -fsS -X POST "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID/wakeup" \
    -H "Authorization: Bearer ${PAPERCLIP_API_KEY:-}" -H "Content-Type: application/json" \
    -d "{\"source\":\"automation\",\"triggerDetail\":\"callback\",\"reason\":\"tester-result-ready\",\"payload\":{\"issueId\":\"$WAKE_ISSUE\"}}" \
    >/dev/null 2>&1 || true
}

# Every exit path leaves a result.json and wakes the Tester, so a killed or
# misconfigured run is reported instead of silently producing nothing.
finish() {
  local rc="$1" sha="${2:-}"
  echo "$rc" > "$STATE/exit"
  python3 "$HERE/parse-test-log.py" "$STATE/log" "$rc" "$sha" "$(cat "$STATE/last-green" 2>/dev/null)" \
    > "$STATE/result.json.tmp" && mv "$STATE/result.json.tmp" "$STATE/result.json"
  [ "$rc" -eq 0 ] && [ -n "$sha" ] && echo "$sha" > "$STATE/last-green"
  rm -f "$STATE/pid"
  wake
}
trap '[ -f "$STATE/exit" ] || finish 99' EXIT
trap 'echo "KILLED: took a signal before cargo reported" >> "$STATE/log"; finish 99; exit 99' HUP INT TERM

. "$HOME/.cargo/env" 2>/dev/null || true
export PATH="$HOME/.local/bin:$PATH"
unset CARGO_TARGET_DIR
command -v cargo >/dev/null && command -v sccache >/dev/null \
  || { echo "ENV BROKEN: cargo/sccache not on PATH" >> "$STATE/log"; finish 96; exit 96; }

git -C "$PROJECT" fetch -q origin main \
  || { echo "STALE BASE: git fetch origin main failed" >> "$STATE/log"; finish 98; exit 98; }
if [ -d "$WT" ]; then
  # The worktree is never edited, so a dirty tree means someone else used it.
  # Refuse rather than discard their changes.
  git -C "$WT" checkout -q --detach origin/main \
    || { echo "WORKTREE: $WT is dirty or broken; not overwriting it" >> "$STATE/log"; finish 97; exit 97; }
else
  git -C "$PROJECT" worktree add -q --detach "$WT" origin/main \
    || { echo "WORKTREE: could not create $WT" >> "$STATE/log"; finish 97; exit 97; }
fi
SHA="$(git -C "$WT" rev-parse HEAD)"
echo "tester: origin/main at $SHA" >> "$STATE/log"
cd "$WT" || { finish 97; exit 97; }
sccache --start-server >/dev/null 2>&1 || true

# Express lane: the FIFO queue routinely holds a day of verifies, and a nightly
# run that waits behind all of them reports on a main that has long moved. One
# build a day cannot starve the normal lane. CGU_DIV=2 matches the Architect's
# test stage, whose memory figures cargo-sem.sh's slot count is derived from.
CARGO_SEM_PRIORITY=1 CARGO_SEM_CGU_DIV=2 "$SEM" env CARGO_INCREMENTAL=0 \
  cargo test --tests --no-fail-fast >> "$STATE/log" 2>&1
rc=$?
# sccache reports a killed rustc as "Compile terminated by signal 15", which
# cargo then prints as an ordinary compile failure.
if [ "$rc" -ne 0 ] && grep -qE "signal: (9|15)|terminated by signal (9|15)" "$STATE/log"; then rc=137; fi
finish "$rc" "$SHA"
exit 0
