#!/usr/bin/env bash
# Cloud overflow verification lane for the Architect.
#
# Runs the clippy/test pass on an Anthropic-managed cloud VM instead of taking a
# slot in cargo-sem.sh, and hands the verdict back. Triage only: the Architect
# still owns rebase, fix, schema regeneration (INSTRUCTIONS.md §6.5), commit and
# push. See the project's docs/ARCHITECT_CLOUD_OVERFLOW.md for when this is
# appropriate at all.
#
# WHY A GIST AND NOT THE PAPERCLIP API. A cloud VM cannot reach localhost:3100 —
# Paperclip runs in Local Trusted Mode and exposing it publicly to carry a single
# pass/fail verdict is a permanent attack surface bought for an occasional
# convenience. Both the VM and this box already authenticate to GitHub, so the
# session publishes its verdict as a secret gist and we poll for it. No tunnel,
# no TLS, no new secret.
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
# some other route, which is what the gist is.
#
# Exit codes deliberately match the Architect's existing verify sentinel:
#   0   verified green
#   1   verified red (compile/test failures; body carries file:line)
#   75  still running (no verdict yet, inside the deadline) — poll again
#   96  environment broken (missing claude/gh/auth) — NOT a build failure
#   98  stale base (branch not pushed, or base moved) — operator resolves
#   99  inconclusive (deadline passed, session never published) — relaunch
set -uo pipefail

STATE_DIR="${CLOUD_VERIFY_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify}"
# A cold Bevy compile on a fresh VM with an empty sccache is the expected case,
# not the exception — this is an overflow path precisely because it is slower per
# build than a warm local one. Deadline is generous for that reason.
DEADLINE="${CLOUD_VERIFY_DEADLINE:-5400}"

die() { printf 'cloud-verify: %s\n' "$*" >&2; exit "${2:-96}"; }

# The marker ties a verdict to an exact commit. Keying on the sha and not just
# the task id is load-bearing: a stale gist from an earlier push of the same
# branch would otherwise be read as a verdict about the current code.
mark_for() { printf 'cloud-verify %s %s' "$1" "$2"; }

verify_prompt() {
  local task="$1" branch="$2" mark="$3"
  cat <<PROMPT
Verify branch ${branch}.

Do NOT edit any files. Do NOT commit. Do NOT push. This is a read-only
verification: a landing that did not go through the Architect would bypass the
schema regeneration gate, so publishing a verdict is the entire job.

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

3. Publish the verdict as a secret gist, exactly this plain-text format:

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

   Write that text to a file, then:
     gh gist create --secret --desc '${mark}' -f verdict.txt <file>

   The description must match '${mark}' character for character — it is how the
   verdict is found. If gh cannot create the gist, say so explicitly; a verdict
   that is not published did not happen.

4. Print the gist URL, then stop.
PROMPT
}

cmd_launch() {
  local task="${1:?task id}" branch="${2:?branch}"
  mkdir -p "$STATE_DIR"

  command -v claude >/dev/null || die "claude not on PATH"
  command -v gh     >/dev/null || die "gh not on PATH"
  command -v script >/dev/null || die "script(1) not on PATH — no way to allocate a pty"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
  # The VM clones the GitHub remote at this branch; it never sees the local
  # worktree. An unpushed task branch would verify whatever the remote last saw.
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 \
    || die "branch $branch is not on origin — push it before offloading" 98

  local head mark out sid
  head="$(git rev-parse HEAD)" || die "cannot read HEAD" 98
  mark="$(mark_for "$task" "$head")"

  out="$(script -qec "claude --cloud $(printf '%q' "$(verify_prompt "$task" "$branch" "$mark")")" /dev/null 2>&1)"
  sid="$(printf '%s' "$out" | sed -n 's/.*\(session_[A-Za-z0-9]\{8,\}\).*/\1/p' | head -1)"
  [ -n "$sid" ] || { printf '%s\n' "$out" >&2; die "no session id in launch output"; }

  printf '%s\n' "$sid"  > "$STATE_DIR/$task.cloud.session"
  printf '%s\n' "$mark" > "$STATE_DIR/$task.cloud.mark"
  date +%s               > "$STATE_DIR/$task.cloud.launched"
  printf 'launched %s session=%s head=%s\n' "$task" "$sid" "$head"
}

cmd_poll() {
  local task="${1:?task id}"
  local mark_file="$STATE_DIR/$task.cloud.mark"
  [ -r "$mark_file" ] || die "no launch state for $task — launch first"
  local mark launched now gist body
  mark="$(cat "$mark_file")"
  launched="$(cat "$STATE_DIR/$task.cloud.launched" 2>/dev/null || echo 0)"
  now="$(date +%s)"

  # Exact-match the description. `gh gist list` is TSV; a substring match could
  # pick up a different task whose id is a prefix of this one.
  gist="$(gh gist list --limit 100 2>/dev/null \
    | awk -F'\t' -v m="$mark" '$2 == m { print $1; exit }')"

  if [ -z "$gist" ]; then
    [ $((now - launched)) -lt "$DEADLINE" ] && exit 75
    die "no verdict after ${DEADLINE}s — session never published; relaunch" 99
  fi

  body="$(gh gist view "$gist" --raw 2>/dev/null)" || die "cannot read gist $gist" 99
  printf '%s\n' "$body"
  case "$(printf '%s' "$body" | sed -n 's/^result: *//p' | head -1)" in
    PASS)  exit 0  ;;
    FAIL)  exit 1  ;;
    STALE) exit 98 ;;
    *)     exit 99 ;;
  esac
}

case "${1:-}" in
  launch) shift; cmd_launch "$@" ;;
  poll)   shift; cmd_poll   "$@" ;;
  *) printf 'usage: %s launch <task-id> <branch> | poll <task-id>\n' "${0##*/}" >&2; exit 2 ;;
esac
