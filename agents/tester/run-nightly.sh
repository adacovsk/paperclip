#!/usr/bin/env bash
# The nightly check of origin/main: clippy -D warnings in both feature sets,
# every test target, then the real game booted headless and each console
# scenario driven through it. Records each stage's verdict as JSON, then wakes the Tester
# to report them.
#
# Runs DETACHED. The Tester launches it and ends its run; this script wakes the
# Tester again when the result is on disk. A run that watched the build instead
# would pay a full context read per poll for an hour or more, and run cost tracks
# turns x context, not wall time.
#
# It builds a dedicated detached worktree of origin/main, never a task branch:
# the point is a verdict on `main`, which every task branch inherits.
#
# Usage:  run-nightly.sh <issue-id-to-wake-on>    (the routine issue's UUID)
#
# State, in ${XDG_CACHE_HOME:-~/.cache}/paperclip-tester/:
#   pid             this run, while it is alive
#   log             setup output, and why the run stopped if it stopped early
#   <stage>.log     cargo's full output for that stage
#   <stage>.exit    its exit status (137 = killed)
#   exit            0 once every stage ran; 96-99 = environment, no verdict
#   result.json     written last; its presence is what the Tester reads
#   last-green      the newest origin/main SHA on which every stage passed
#
# The verdict is also posted as a `tester/nightly` commit status on the SHA it
# checked. A session asking "is main green?" starts at GitHub, where every
# Actions run may be a zero-step billing rejection; the status is the one Rust
# reading there that actually ran, and its link lists the issues filed for it.
set -u

WAKE_ISSUE="${1:?usage: run-nightly.sh <issue-id>}"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-tester"
PROJECT="${PAPERCLIP_PROJECT:-$HOME/code/bevy-rpg}"
REPO="${TESTER_REPO:-adacovsk/bevy-rpg}"
WT="${TESTER_WORKTREE:-$HOME/code/bevy-rpg-tester}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SEM="$HERE/../architect/cargo-sem.sh"

#: name | extra cargo-sem env | cargo command. The two clippy spellings are
#: pixi.toml's `clippy-default` and `clippy-ci`, so a red stage reproduces with
#: one `pixi run`. Default-feature clippy runs first and the test build follows
#: it, so the two default-feature stages share dependency artifacts; the
#: `--no-default-features` stage rebuilds dependencies, so it goes last. The test
#: stage takes CGU_DIV=2 like the Architect's, whose memory figures
#: cargo-sem.sh's slot count is derived from.
STAGES=(
  "clippy-default||cargo clippy --all-targets -- -D warnings -A dead-code -A unused-imports"
  "test|CARGO_SEM_CGU_DIV=2|cargo test --tests --no-fail-fast"
  "clippy-no-default-features||cargo clippy --no-default-features --all-targets -- -D warnings -A dead-code -A unused-imports"
)
#: The headless runs, `name|game arguments`; filled once the checkout exists.
HEADLESS=()

mkdir -p "$STATE"
if [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; then
  echo "already running (pid $(cat "$STATE/pid"))"
  exit 0
fi
echo $$ > "$STATE/pid"
rm -f "$STATE/result.json" "$STATE/exit" "$STATE"/*.exit "$STATE"/*.log
: > "$STATE/log"

wake() {
  [ -n "${PAPERCLIP_API_URL:-}" ] && [ -n "${PAPERCLIP_AGENT_ID:-}" ] || return 0
  curl -fsS -X POST "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID/wakeup" \
    -H "Authorization: Bearer ${PAPERCLIP_API_KEY:-}" -H "Content-Type: application/json" \
    -d "{\"source\":\"automation\",\"triggerDetail\":\"callback\",\"reason\":\"tester-result-ready\",\"payload\":{\"issueId\":\"$WAKE_ISSUE\"}}" \
    >/dev/null 2>&1 || true
}

# Best effort: a failed post must not cost the Tester its wake. The issues the
# Tester files carry the SHA in their body, so a search on it finds them.
post_status() {
  local sha="$1" state="$2" desc="$3"
  [ -n "$sha" ] || return 0
  gh api -X POST "repos/$REPO/statuses/$sha" -f context=tester/nightly \
    -f state="$state" -f description="${desc:0:140}" \
    -f target_url="https://github.com/$REPO/issues?q=is%3Aissue+label%3Atest-failure+$sha" \
    >/dev/null 2>&1 || echo "STATUS: could not post $state on $sha" >> "$STATE/log"
}

# success only when every stage ran and passed; failure when a stage that ran
# found something; error when no stage could give a verdict (killed, not run).
status_from_result() {
  python3 - "$STATE/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
parts, found, unknown = [], False, False
for name, st in r.get("stages", {}).items():
    if not st.get("ran"):
        unknown = True; parts.append(f"{name} not run")
    elif st["exit"] == 0:
        parts.append(f"{name} ok")
    elif st["exit"] == 137:
        unknown = True; parts.append(f"{name} killed")
    else:
        found = True
        n = len(st.get("failed") or st.get("diagnostics") or [])
        if name.startswith(("smoke", "scenario-")):
            parts.append(f"{name} failed")
        else:
            parts.append(f"{name} {n or '?'} failed" if name == "test" else f"{name} {n or '?'} errors")
state = "failure" if found else "error" if unknown or r.get("exit") else "success"
print(state); print("; ".join(parts) or f"no verdict (exit {r.get('exit')})")
PY
}

# Every stage ran and exited 0. A stage with no exit file never ran.
all_green() {
  local s
  for s in "${STAGES[@]}" "${HEADLESS[@]}"; do
    [ "$(cat "$STATE/${s%%|*}.exit" 2>/dev/null)" = 0 ] || return 1
  done
}

# Every exit path leaves a result.json and wakes the Tester, so a killed or
# misconfigured run is reported instead of silently producing nothing.
finish() {
  local rc="$1" sha="${2:-}"
  echo "$rc" > "$STATE/exit"
  python3 "$HERE/parse-nightly.py" "$STATE" "$sha" "$(cat "$STATE/last-green" 2>/dev/null)" \
    > "$STATE/result.json.tmp" && mv "$STATE/result.json.tmp" "$STATE/result.json"
  if [ "$rc" -eq 0 ] && [ -n "$sha" ] && all_green; then
    echo "$sha" > "$STATE/last-green"
  fi
  if [ -n "$sha" ] && [ -f "$STATE/result.json" ]; then
    local verdict
    verdict="$(status_from_result)"
    post_status "$sha" "${verdict%%$'\n'*}" "${verdict#*$'\n'}"
  fi
  rm -f "$STATE/pid"
  wake
}
trap '[ -f "$STATE/exit" ] || finish 99 "${SHA:-}"' EXIT
trap 'echo "KILLED: took a signal before every stage reported" >> "$STATE/log"; finish 99 "${SHA:-}"; exit 99' HUP INT TERM

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
post_status "$SHA" pending "nightly clippy x2 + tests + headless running"
cd "$WT" || { finish 97; exit 97; }
sccache --start-server >/dev/null 2>&1 || true

# Headless stages: the real game under DefaultPlugins, which no test target
# reaches — they all run under MinimalPlugins, so boot-path panics (query
# conflicts, missing resources, world generation) and anything a scenario drives
# pass every test. `--smoke` boots to InGame and exits; each project
# `scripts/smoke/*.smoke` drives console commands through a run. Any non-zero
# exit is a finding. Discovered from the checkout, so a new scenario runs the
# night it lands with no edit here.
#
# ONE BUILD, PARALLEL RUNS. The binary is built once, as its own cargo-sem.sh
# stage after the test stage (whose default-feature dependency artifacts it
# reuses). A run is not a compile, so the runs take no cargo slot: they start the
# moment the build is green, HEADLESS_JOBS at a time, alongside the remaining
# clippy stage. Each runs in its own sandbox under $STATE — the worktree's
# `assets` and `scripts` symlinked in, an empty `saves/` — because the game writes
# `saves/` relative to its working directory: parallel runs in one directory
# would race on it, and a run in the worktree would leave it holding files the
# next night's checkout has to step around. An empty `saves/` is the state a
# fresh checkout boots from, which is what the Architect's smoke step sees.
GAME_BIN=rust-bevy-rpg  # <!-- privacy-ok: cargo needs the literal bin name -->
HEADLESS_JOBS="${TESTER_HEADLESS_JOBS:-2}"
HEADLESS_TIMEOUT="${TESTER_HEADLESS_TIMEOUT:-900}"
HEADLESS=("smoke|--smoke")
for scenario in scripts/smoke/*.smoke; do
  [ -f "$scenario" ] || continue
  HEADLESS+=("scenario-$(basename "$scenario" .smoke)|--script scripts/smoke/$(basename "$scenario")")
done
STAGES=("${STAGES[@]:0:2}" "game-build||cargo build --bin $GAME_BIN" "${STAGES[@]:2}")

# Every headless run, HEADLESS_JOBS at a time. Run without cargo, so the binary
# needs what `cargo run` would have supplied: the toolchain's and the build's
# shared libraries (the dev profile links Bevy dynamically), and an asset root —
# Bevy otherwise looks beside the executable.
run_headless() {
  local bin="$WT/target/debug/$GAME_BIN" libs entry name args box running=0
  libs="$WT/target/debug/deps:$WT/target/debug:$(rustc --print target-libdir)"
  for entry in "${HEADLESS[@]}"; do
    name="${entry%%|*}" args="${entry#*|}" box="$STATE/headless/${entry%%|*}"
    rm -rf "$box" && mkdir -p "$box/saves" && ln -s "$WT/assets" "$box/assets" && ln -s "$WT/scripts" "$box/scripts"
    # shellcheck disable=SC2086  # $args is word-split on purpose
    ( cd "$box" && env -u DISPLAY -u WAYLAND_DISPLAY WGPU_ADAPTER_NAME=llvmpipe \
        LD_LIBRARY_PATH="$libs" BEVY_ASSET_ROOT="$box" CARGO_MANIFEST_DIR="$box" \
        timeout "$HEADLESS_TIMEOUT" "$bin" $args > "$STATE/$name.log" 2>&1
      echo $? > "$STATE/$name.exit" ) &
    running=$((running + 1))
    if [ "$running" -ge "$HEADLESS_JOBS" ]; then wait -n; running=$((running - 1)); fi
  done
  wait
}

# Express lane: the FIFO queue routinely holds a day of verifies, and a nightly
# run that waits behind all of them reports on a main that has long moved. One
# run a night cannot starve the normal lane.
#
# Every stage runs whatever the one before it did: a run that stops at its first
# red stage reports one problem and hides the rest. Each is its own cargo-sem.sh
# call, because the semaphore refuses a chain of cargos inside one acquisition.
for stage in "${STAGES[@]}"; do
  IFS='|' read -r name extra cmd <<< "$stage"
  # shellcheck disable=SC2086  # $extra and $cmd are word-split on purpose
  env CARGO_SEM_PRIORITY=1 $extra "$SEM" env CARGO_INCREMENTAL=0 $cmd > "$STATE/$name.log" 2>&1
  rc=$?
  # sccache reports a killed rustc as "Compile terminated by signal 15", which
  # cargo then prints as an ordinary compile failure.
  if [ "$rc" -ne 0 ] && grep -qE "signal: (9|15)|terminated by signal (9|15)" "$STATE/$name.log"; then rc=137; fi
  echo "$rc" > "$STATE/$name.exit"
  if [ "$name" = game-build ] && [ "$rc" -eq 0 ]; then run_headless & HEADLESS_PID=$!; fi
done
# A red build leaves the headless stages without exit files: "not run", no verdict.
[ -n "${HEADLESS_PID:-}" ] && wait "$HEADLESS_PID"
finish 0 "$SHA"
exit 0
