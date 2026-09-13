#!/usr/bin/env bash
# Cloud verification lane for the Architect.
#
# Moves the cargo half of a verify onto an Anthropic-managed cloud VM: clippy and
# tests, fixes inside the task's own files, the non-Rust guard suite, and schema
# regeneration last. See the project's docs/ARCHITECT_CLOUD_OVERFLOW.md.
#
# TRUST BOUNDARY. The VM does work; it never lands it. It builds the exact
# commit this box pushed, and publishes its commits only under its own
# `cloud-verify/` branch — never the task branch, never a PR. This box then
# accepts or rejects those commits (`accept_cloud_work`): they must descend from
# the launched head, touch only the task's files or regenerated schemas, add no
# lint or test suppression, and pass the guard suite locally. Accepted work is
# fast-forwarded into the worktree and the Architect lands it through its
# ordinary Landing; rejected work is never used and the task verifies locally.
# The operator's merge remains the final gate.
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
# The cloud-verify branch carries the VM's fix commits (if any) topped by one
# empty verdict commit whose message IS the verdict. It lives nowhere near
# `task/*`, nothing merges it, and poll deletes the remote copy as soon as it has
# fetched it. The prompt forbids pushing any other ref and opening a PR.
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
  local task="$1" head="$2" ref="$3" cap="$4"
  cat <<PROMPT
Verify commit ${head} of task ${task}, fixing what you can within the task's scope.

WHATEVER HAPPENS BELOW — stopping early, running out of context, hitting a wall
— END with step 8. A result that exists only in your transcript was never
delivered: the machine waiting on you cannot tell it from a crashed session.

HARD LIMITS. The only ref you may push is ${ref}. Never push any other branch,
never open, comment on or merge a pull request, never change repository
settings. Your commits are inspected before anything uses them, and work that
breaks these rules is discarded.

1. git fetch origin ${head} && git checkout --detach ${head}
   Do NOT rebase or merge — the other side already put this commit on main and
   will check that your commits descend from it.
   git fetch origin main
   BASE=\$(git merge-base HEAD origin/main)
   The task's files are: git diff --name-only \$BASE HEAD

2. Gate commands. Record each exit status.
     cargo clippy --all-targets
     cargo test --lib
     cargo clippy --no-default-features      (only if the task's files include src/**.rs)
     cargo test --test <name>                (for each tests/<name>.rs among the task's files)
   No semaphore, no CARGO_INCREMENTAL, no job or codegen-unit limits.
   On 'No space left on device': cargo clean -p rust-bevy-rpg, then re-run.

3. Fix failures, at most ${cap} rounds of fix -> commit -> re-run step 2.
   ONLY in the task's files. An error in any other file is not yours: do not edit
   it; finish with result: FAIL and name it. Fix causes, not symptoms: adding
   #[allow(...)], #[expect(...)] or #[ignore], deleting a test, or weakening an
   assertion gets all of your work rejected. Commit each round as
   'fix: <what>' with a 'Stage: architect' line. Still red after ${cap} rounds
   -> result: FAIL.

4. Non-Rust guards:  PYTHONPATH=scripts bash scripts/verify.sh
   Fix what it flags in the task's files, commit, re-run. Same limits.

5. Report-only, never a gate and never a fix:
     cargo test --tests --no-fail-fast
   Record the exit status and the names of failing tests.

6. LAST, after your final fix commit:
     git diff --name-only \$BASE HEAD | python3 scripts/check_schema_regen.py
   Exit 0 -> schemas: not-relevant. Exit 1 -> run as ONE chained command:
     cargo run --bin generate_schemas && git diff --exit-code assets/schemas/
   Non-empty diff -> commit only assets/schemas/ ('chore: regenerate schemas')
   and run the chain again until empty -> schemas: regenerated. Empty the first
   time -> schemas: proved-empty. The generator failing -> result: FAIL.
   No fix commit may follow this step.

7. Write the verdict text to a file:

CLOUD-VERIFY-V2
task: ${task}
launched: ${head}
base: <\$BASE>
result: PASS | FAIL
fixes: <rounds used in step 3>
schemas: not-relevant | regenerated | proved-empty
guards: <exit status of step 4>
integration: <exit status of step 5>
cmd: <command> = <exit status>        (one line per command you ran)
--- errors ---
<empty on PASS; otherwise the full compiler/guard output with file:line>

   result is PASS only if every step-2 gate and step 4 exited 0 and step 6 did
   not fail.

8. Publish — your commits plus the verdict, to ${ref} and nowhere else:
     git commit --allow-empty -F <file>
     git push origin HEAD:${ref}
   If the push fails, print the error. Then stop.
PROMPT
}

cmd_launch() {
  local task="${1:?task id}" branch="${2:?branch}"
  mkdir -p "$STATE_DIR"

  command -v claude >/dev/null || die "claude not on PATH"
  command -v script >/dev/null || die "script(1) not on PATH — no way to allocate a pty"
  # The VM clones the GitHub remote; it never sees the local worktree.
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 \
    || die "branch $branch is not on origin — push it before offloading" 98

  local head ref out sid
  head="$(git rev-parse HEAD)" || die "cannot read HEAD" 98
  ref="$(ref_for "$task" "$head")"

  # `--effort` must precede `--cloud`: `--cloud` takes an optional description,
  # so `--cloud --effort low "..."` swallows the flag and the prompt never arrives.
  out="$(script -qec "claude --effort ${CLOUD_VERIFY_EFFORT:-low} --cloud $(printf '%q' "$(verify_prompt "$task" "$head" "$ref" "${CLOUD_VERIFY_FIX_CAP:-3}")")" /dev/null 2>&1)"
  sid="$(printf '%s' "$out" | sed -n 's/.*\(session_[A-Za-z0-9]\{8,\}\).*/\1/p' | head -1)"
  [ -n "$sid" ] || { printf '%s\n' "$out" >&2; die "no session id in launch output"; }

  printf '%s\n' "$sid"  > "$STATE_DIR/$task.cloud.session"
  printf '%s\n' "$ref"  > "$STATE_DIR/$task.cloud.ref"
  printf '%s\n' "$head" > "$STATE_DIR/$task.cloud.launched-head"
  date +%s              > "$STATE_DIR/$task.cloud.launched"
  printf 'launched %s session=%s head=%s ref=%s\n' "$task" "$sid" "$head" "$ref"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1; }

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
  printf '%s\n' "$body" > "$STATE_DIR/$task.cloud.verdict"
  printf '%s\n' "$body"
  case "$(field "$body" result)" in
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
  # The Architect and the Coordinator's sweep judge liveness by probing
  # /proc/$(cat <task>.pid). Without it a running cloud verify reads as a dead
  # build, and the re-dispatch that follows offloads the same task a second time.
  echo $$ > "$STATE_DIR/$task.pid"

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
  # The verdict is a claim; the commits are untrusted input. Nothing downstream —
  # the Architect's Landing or the Coordinator's sweep — sees a green sentinel
  # until this box has accepted them.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    ( accept_cloud_work "$task" ) >> "$STATE_DIR/$task.cloud.log" 2>&1 || rc=95
  fi
  printf '%s\n' "$rc" > "$exit_file"
  wake "$task"
}

reject() { printf '%s\n' "$1" > "$STATE_DIR/$TASK.cloud.rejected"; echo "REJECTED: $1"; exit 1; }

# Accept the VM's commits into the worktree, or refuse them. Refusal writes
# `<task>.cloud.rejected`, which also closes the lane for that task so the
# Architect verifies it locally rather than re-offloading into the same result.
accept_cloud_work() {
  TASK="$1"
  local ref lease base work f bad
  ref="$(cat "$STATE_DIR/$TASK.cloud.ref")"
  lease="$(cat "$STATE_DIR/$TASK.cloud.launched-head" 2>/dev/null)"
  base="$(cat "$STATE_DIR/$TASK.base" 2>/dev/null)"
  [ -n "$lease" ] && [ -n "$base" ] || reject "launch state missing (launched-head/base)"
  work="$(git rev-parse --verify -q "$ref^")" || reject "verdict commit has no parent"

  git diff --quiet "$work" "$ref" || reject "verdict commit carries file changes"
  [ "$(git rev-parse HEAD)" = "$lease" ] || reject "worktree moved since launch"
  [ -z "$(git status --porcelain)" ] || reject "worktree dirty since launch"
  git merge-base --is-ancestor "$lease" "$work" || reject "cloud commits do not descend from the launched head"

  # Scope: every file the VM changed must already be one of the task's files,
  # or a regenerated schema.
  bad=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in assets/schemas/*) continue ;; esac
    git diff --name-only "$base" "$lease" | grep -qxF -- "$f" || bad="$bad $f"
  done < <(git diff --name-only "$lease" "$work")
  [ -z "$bad" ] || reject "cloud commits touch files outside the task:$bad"

  # The prompt forbids these; this is what makes the prohibition hold.
  if git diff -U0 "$lease" "$work" -- '*.rs' \
       | grep -qE '^\+.*(#!?\[(allow|expect)\(|#\[ignore)'; then
    reject "cloud commits add a lint or test suppression"
  fi
  if git diff --diff-filter=D --name-only "$lease" "$work" | grep -q .; then
    reject "cloud commits delete files"
  fi

  git merge -q --ff-only "$work" || reject "fast-forward to cloud work failed"
  if [ "$work" != "$lease" ]; then
    export PATH="${CLOUD_VERIFY_PIXI_BIN:-$HOME/.pixi/bin}:$PATH"
    if ! command -v pixi >/dev/null || ! pixi run -e dev verify; then
      git reset -q --hard "$lease"
      reject "guard suite failed (or pixi unavailable) on the cloud commits"
    fi
  fi

  local integ
  integ="$(field "$(cat "$STATE_DIR/$TASK.cloud.verdict")" integration)"
  case "$integ" in ''|*[!0-9]*) rm -f "$STATE_DIR/$TASK.integration" ;; *) printf '%s\n' "$integ" > "$STATE_DIR/$TASK.integration" ;; esac
  printf '%s\n' "$work" > "$STATE_DIR/$TASK.cloud.head"
  echo "accepted: worktree at $work ($(git rev-list --count "$lease..$work") cloud commit(s))"
}

# The Architect's only entry point to the lane. Exit 0 = offloaded (a watch is
# detached; exit the run as for a local launch). Exit 1 = lane closed; run the
# local chain instead. Declining is never an error and writes no sentinel.
#
# There is deliberately no concurrency bound: while weekly usage is behind the
# calendar every verify goes to the cloud, and the flood is bounded by the quota
# it spends closing the gate. The gate is here rather than in INSTRUCTIONS.md so
# no Architect run can offload without passing it.
cmd_offload() {
  local task="${1:?task id}" branch="${2:?branch}" open
  [ "${ARCHITECT_CLOUD_LANE:-}" = "1" ] || { echo "cloud lane off (ARCHITECT_CLOUD_LANE unset) — run locally"; exit 1; }
  [ ! -f "$STATE_DIR/$task.cloud.rejected" ] || { echo "cloud work for $task was rejected ($(cat "$STATE_DIR/$task.cloud.rejected")) — run locally"; exit 1; }
  mkdir -p "$STATE_DIR"
  open="$(python3 "$(dirname "$0")/cloud-pace.py" 2>>"$STATE_DIR/pace.log")" || open=0
  if [ "$open" != "1" ]; then
    echo "not offloaded: $(tail -1 "$STATE_DIR/pace.log" 2>/dev/null) — run locally"
    exit 1
  fi
  # The VM clones the remote, and Step 0's rebase has usually rewritten the branch
  # locally, so publish exactly this head. The base recorded here is what
  # acceptance scopes the VM's changes against.
  [ "$(git branch --show-current)" = "$branch" ] || { echo "not on $branch — run locally"; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo "uncommitted changes — commit them first"; exit 1; }
  git fetch -q origin main && git merge-base HEAD origin/main > "$STATE_DIR/$task.base" \
    || { echo "cannot read origin/main — run locally"; exit 1; }
  git push -q --force-with-lease -u origin "HEAD:$branch" || { echo "push of $branch failed — run locally"; exit 1; }
  rm -f "$STATE_DIR/$task.exit" "$STATE_DIR/$task.cloud.head" "$STATE_DIR/$task.cloud.verdict"
  setsid "$0" watch "$task" "$branch" >/dev/null 2>&1 < /dev/null &
  echo "offloaded $task: $(tail -1 "$STATE_DIR/pace.log" 2>/dev/null)"
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
  offload) shift; cmd_offload "$@" ;;
  accept)  shift; accept_cloud_work "$@" ;;
  *) printf 'usage: %s offload <task-id> <branch> | launch <task-id> <branch> | poll <task-id> | watch <task-id> <branch>\n' "${0##*/}" >&2; exit 2 ;;
esac
