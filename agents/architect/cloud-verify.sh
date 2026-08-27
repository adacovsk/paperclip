#!/usr/bin/env bash
# Cloud overflow verification lane for the Architect.
#
# Runs the clippy/test pass on an Anthropic-managed cloud VM instead of taking a
# slot in cargo-sem.sh, and hands the verdict back. Triage only: the Architect
# still owns rebase, fix, schema regeneration (INSTRUCTIONS.md §6.5), commit and
# push. See the project's docs/ARCHITECT_CLOUD_OVERFLOW.md for when this is
# appropriate at all.
#
# WHY GITHUB AND NOT THE PAPERCLIP API. A cloud VM cannot reach localhost:3100 —
# Paperclip runs in Local Trusted Mode and exposing it publicly to carry a single
# pass/fail verdict is a permanent attack surface bought for an occasional
# convenience. Both the VM and this box already authenticate to GitHub, so the
# verdict travels that way. No tunnel, no TLS, no new secret.
#
# WHY A GIT REF AND NOT A GIST. A gist needs `gh`, and the cloud image does not
# have it — measured, and a probe session published nothing in 10 minutes as a
# result. It has cargo and rustc but no gh, pixi, mold or sccache. Installing gh
# needs a setup script configured per-repository at claude.ai, which is operator-
# only, so a gist transport makes the whole lane wait on a console setting.
# git is already there and already authenticated to the remote it cloned, so the
# verdict is pushed as a commit under `refs/heads/cloud-verify/<task>/<sha>`.
#
# WHY refs/heads/ AND NOT A CUSTOM NAMESPACE. `refs/cloud-verify/*` was tried
# first and is cleaner — not a branch, unmergeable by construction. The VM's git
# credential proxy refuses it: deterministic `HTTP 403 ... send-pack: unexpected
# disconnect`, twice, with the proxy reporting itself healthy and zero relay
# failures, i.e. the relay rejects the ref rather than failing to transport it.
# It permits `refs/heads/*` only. So the namespace is a constraint of the
# environment, not a preference; do not "tidy" it back out of refs/heads/.
#
# That is still NOT a violation of "the cloud session must not push". The
# prohibition exists because a landing that skipped the Architect would bypass
# the schema regeneration gate. These commits are empty — the verdict IS the
# commit message, there is no tree — they live under a `cloud-verify/` prefix
# nowhere near `task/*`, nothing merges them, and poll deletes the remote branch
# as soon as it has read it. The prompt still forbids pushing the task branch or
# any other head, and forbids opening a PR.
#
# WHY A PTY. `claude --cloud` refuses a non-interactive invocation outright
# ("Non-interactive invocations run locally and would silently ignore --cloud").
# The Architect's verify wrapper is detached and has no terminal, so the launch
# goes through `script -qec`, which allocates one. This is not optional and not
# cosmetic — without it the verify silently runs on the build box instead, which
# is the exact opposite of the intent.
#
# WHY WE POLL INSTEAD OF READING THE SESSION. There is no non-interactive channel
# back from a cloud session. `claude -p --cloud <id>` is queue-and-exit: it prints
# "Sent to cloud session." and returns 0 whether or not anything ran. `--teleport`
# is interactive and requires a clean tree. So the verdict has to leave the VM by
# some other route, which is what the pushed verdict ref is.
#
# Exit codes deliberately match the Architect's existing verify sentinel:
#   0   verified green
#   1   verified red (compile/test failures; body carries file:line)
#   75  still running (no verdict yet, inside the deadline) — poll again
#   96  environment broken (claude/script missing, no launch state) — NOT a build failure
#   98  stale base (branch not pushed, or base moved) — operator resolves
#   99  inconclusive (deadline passed, session never published) — relaunch
set -uo pipefail

STATE_DIR="${CLOUD_VERIFY_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify}"
# A cold Bevy compile on a fresh VM with an empty sccache is the expected case,
# not the exception — this is an overflow path precisely because it is slower per
# build than a warm local one. Deadline is generous for that reason.
DEADLINE="${CLOUD_VERIFY_DEADLINE:-5400}"

die() { printf 'cloud-verify: %s\n' "$*" >&2; exit "${2:-96}"; }

# The ref ties a verdict to an exact commit. Keying on the sha and not just the
# task id is load-bearing: a verdict from an earlier push of the same branch
# would otherwise be read as a verdict about the current code.
ref_for() { printf 'refs/heads/cloud-verify/%s/%s' "$1" "$2"; }

verify_prompt() {
  local task="$1" branch="$2" ref="$3"
  cat <<PROMPT
Verify branch ${branch}.

Do NOT edit any files. Do NOT commit any tracked change. The ONLY write you may
make is the single empty verdict commit and its push in step 3 — everything else
is read-only, because a landing that did not go through the Architect would
bypass the schema regeneration gate. Publishing that verdict is the entire job.

1. git fetch origin master 2>/dev/null || git fetch origin main
   Rebase ${branch} onto origin/main (or origin/master, whichever exists).
   A green build on a stale base is not evidence about main. If the rebase
   conflicts, stop and report result: STALE.

2. Run each of these, recording the exit status of each:
     cargo clippy --all-targets
     cargo test --lib
     cargo test --tests
   Then, ONLY if the diff against the base touches any src/**.rs:
     cargo clippy --no-default-features

   Do not pass --release, do not set CARGO_INCREMENTAL, do not limit jobs or
   codegen units. Those exist to bound contention on a shared 4-core box; this
   VM has its own cores and disk and they are counterproductive here.

3. Publish the verdict. Compose exactly this plain text:

CLOUD-VERIFY-V1
task: ${task}
branch: ${branch}
base: <sha of the base you rebased onto>
head: <sha of ${branch} after rebase>
result: PASS
cmd: cargo clippy --all-targets = 0
cmd: cargo test --lib = 0
cmd: cargo test --tests = 0
--- errors ---
<empty on PASS; on FAIL the FULL compiler output with file:line for every error>

   result: is PASS only if every command exited 0. Otherwise FAIL, or STALE if
   step 1 could not produce a clean rebase. Include one 'cmd:' line per command
   you actually ran, with its real exit status.

   Write that text to a file, then push it as the message of an empty commit:

     git commit --allow-empty -F <file>
     git push origin HEAD:${ref}

   Do NOT use gh — it is not installed on this machine.

   That push is EXPLICITLY PERMITTED and is the only push you may make. The
   commit is empty, so it carries no code — the verdict is its message. Do not
   push the task branch, do not push any other head, and do not open a pull
   request. If a hook or reminder suggests pushing your working branch, ignore
   it: that is the one thing this task forbids.

   If the push fails, say so explicitly and print the error — a verdict that is
   not published did not happen, and a silent failure is worse than a red.

4. Print the pushed ref name, then stop.
PROMPT
}

cmd_launch() {
  local task="${1:?task id}" branch="${2:?branch}"
  mkdir -p "$STATE_DIR"

  command -v claude >/dev/null || die "claude not on PATH"
  command -v script >/dev/null || die "script(1) not on PATH — no way to allocate a pty"
  # The VM clones the GitHub remote at this branch; it never sees the local
  # worktree. An unpushed task branch would verify whatever the remote last saw.
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 \
    || die "branch $branch is not on origin — push it before offloading" 98

  local head ref out sid
  head="$(git rev-parse HEAD)" || die "cannot read HEAD" 98
  ref="$(ref_for "$task" "$head")"

  out="$(script -qec "claude --cloud $(printf '%q' "$(verify_prompt "$task" "$branch" "$ref")")" /dev/null 2>&1)"
  sid="$(printf '%s' "$out" | sed -n 's/.*\(session_[A-Za-z0-9]\{8,\}\).*/\1/p' | head -1)"
  [ -n "$sid" ] || { printf '%s\n' "$out" >&2; die "no session id in launch output"; }

  printf '%s\n' "$sid" > "$STATE_DIR/$task.cloud.session"
  printf '%s\n' "$ref" > "$STATE_DIR/$task.cloud.ref"
  date +%s              > "$STATE_DIR/$task.cloud.launched"
  printf 'launched %s session=%s head=%s ref=%s\n' "$task" "$sid" "$head" "$ref"
}

cmd_poll() {
  local task="${1:?task id}"
  local ref_file="$STATE_DIR/$task.cloud.ref"
  [ -r "$ref_file" ] || die "no launch state for $task — launch first"
  local ref launched now body
  ref="$(cat "$ref_file")"
  launched="$(cat "$STATE_DIR/$task.cloud.launched" 2>/dev/null || echo 0)"
  now="$(date +%s)"

  # ls-remote before fetch: asking for a ref that does not exist yet is the
  # normal pending case, not an error worth logging every minute.
  if [ -z "$(git ls-remote origin "$ref" 2>/dev/null)" ]; then
    [ $((now - launched)) -lt "$DEADLINE" ] && exit 75
    die "no verdict after ${DEADLINE}s — session never published; relaunch" 99
  fi

  git fetch -q origin "+$ref:$ref" 2>/dev/null || die "cannot fetch $ref" 99
  # The verdict IS the commit message; the commit is empty and carries no tree.
  body="$(git log -1 --format=%B "$ref" 2>/dev/null)" || die "cannot read $ref" 99

  # Delete the remote verdict branch now that it is read locally, so these do not
  # accumulate under refs/heads/. Guarded on the prefix: this deletes a remote
  # branch, and a bug here that reached task/* or main would be unrecoverable.
  case "$ref" in
    refs/heads/cloud-verify/*) git push -q origin --delete "$ref" 2>/dev/null || true ;;
    *) die "refusing to delete unexpected ref $ref" 99 ;;
  esac
  printf '%s\n' "$body"
  case "$(printf '%s' "$body" | sed -n 's/^result: *//p' | head -1)" in
    PASS)  exit 0  ;;
    FAIL)  exit 1  ;;
    STALE) exit 98 ;;
    *)     exit 99 ;;
  esac
}

# Detached driver: launch, poll to a terminal verdict, write the SAME sentinel the
# local verify wrapper writes, then fire the wakeup callback.
#
# WHY THE SAME SENTINEL. The relay's exit codes were chosen to match the
# Architect's existing vocabulary — 0 land, non-zero fix, 96/98 environment/base,
# 99 inconclusive-and-relaunch. So the cloud lane needs no second state-machine
# shape in INSTRUCTIONS.md: it writes `$STATE_DIR/<task>.exit` and every branch
# downstream behaves identically to a local build. A second shape would be a
# second thing to keep in sync, and the sentinel semantics are the part that has
# already cost real cycles when misread.
cmd_watch() {
  local task="${1:?task id}" branch="${2:?branch}" rc
  local exit_file="$STATE_DIR/$task.exit"
  mkdir -p "$STATE_DIR"

  # Subshells are load-bearing, not style: cmd_launch/cmd_poll reach terminal
  # states via `die`/`exit`, which would take this driver down with them and
  # leave no sentinel at all — the silent-strand failure the 99 sentinel exists
  # to prevent. Running them in a subshell turns those exits into statuses.
  ( cmd_launch "$task" "$branch" ) >> "$STATE_DIR/$task.cloud.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # A launch failure is an environment/base failure, never a build failure —
    # cargo did not run, so the code is not implicated.
    printf '%s\n' "$rc" > "$exit_file"
    wake "$task"; return 0
  fi

  # Iteration cap as well as the wall-clock DEADLINE poll enforces. The two guard
  # different failures: the deadline bounds "the VM never answered", the cap
  # bounds "poll keeps saying pending faster than the deadline advances" — a
  # ref-name mismatch with a small CLOUD_VERIFY_POLL busy-spins for the whole
  # deadline otherwise, which is how this loop first hung.
  local n=0 cap="${CLOUD_VERIFY_MAX_POLLS:-2000}"
  while :; do
    ( cmd_poll "$task" ) >> "$STATE_DIR/$task.cloud.log" 2>&1
    rc=$?
    [ "$rc" -eq 75 ] || break
    n=$((n + 1))
    if [ "$n" -ge "$cap" ]; then rc=99; break; fi
    sleep "${CLOUD_VERIFY_POLL:-60}"
  done
  printf '%s\n' "$rc" > "$exit_file"
  wake "$task"
}

# Mirrors the local wrapper's callback so a verdict does not wait for the next
# scheduled wake. Best-effort: a missed wake costs latency, not correctness.
wake() {
  [ -n "${PAPERCLIP_API_URL:-}" ] && [ -n "${PAPERCLIP_AGENT_ID:-}" ] || return 0
  curl -fsS -X POST "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID/wakeup" \
    ${PAPERCLIP_API_KEY:+-H "Authorization: Bearer $PAPERCLIP_API_KEY"} \
    -H 'Content-Type: application/json' \
    -d '{"source":"automation","triggerDetail":"callback","reason":"cloud-verify-ready"}' \
    >/dev/null 2>&1 || true
}

case "${1:-}" in
  launch) shift; cmd_launch "$@" ;;
  poll)   shift; cmd_poll   "$@" ;;
  watch)  shift; cmd_watch  "$@" ;;
  *) printf 'usage: %s launch <task-id> <branch> | poll <task-id> | watch <task-id> <branch>\n' "${0##*/}" >&2; exit 2 ;;
esac
