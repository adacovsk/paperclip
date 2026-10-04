#!/usr/bin/env bash
# Cloud verification lane for the Architect.
#
# Moves the cargo half of a verify onto an Anthropic-managed cloud VM: clippy and
# tests, fixes inside the task's own files (plus the out-of-scope errors the
# task's own diff caused, declared and bounded — see `check_out_of_scope`), the
# non-Rust guard suite, and schema regeneration last. See the project's docs/ARCHITECT_CLOUD_OVERFLOW.md.
#
# TRUST BOUNDARY. The VM does work; it never lands it. It builds the exact
# commit this box pushed, and publishes its commits only under its own
# `cloud-verify/` branch — never the task branch, never a PR. This box then
# accepts or rejects those commits (`accept_cloud_work`): they must descend from
# the launched head, touch only the task's files, regenerated schemas or declared
# diff-caused fixes, add no lint or test suppression, delete no file, and pass
# the guard suite locally. Accepted work is
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
#   99  inconclusive (deadline passed with no verdict ref; the session may still publish late) — relaunch
set -uo pipefail

STATE_DIR="${CLOUD_VERIFY_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/paperclip-verify}"
# A cold Bevy compile on a fresh VM with an empty sccache is the expected case,
# not the exception — this is an overflow path precisely because it is slower per
# build than a warm local one. Deadline is generous for that reason.
#
# Do not lower this back toward 90 minutes. Most sessions publish in under an
# hour, but a slow tail runs far longer: fix rounds, a disk-full `cargo clean`
# and a second schema regeneration each add a rebuild, and sessions in that tail
# have published at 128 and 150 minutes. At a 90-minute deadline those verdicts
# arrived after this side had already written 99 and relaunched, so the lane read
# as "never publishes" while it was publishing late, and two late 99s in a row
# escalated a verified task to the operator. A session that is truly dead costs
# only detection latency here; a deadline shorter than the tail throws away
# finished verdicts and pays for the build twice.
DEADLINE="${CLOUD_VERIFY_DEADLINE:-10800}"

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
     cargo clippy --all-targets -- -D warnings -A dead-code -A unused-imports
     cargo test --lib
     cargo clippy --no-default-features -- -D warnings -A dead-code -A unused-imports
                                             (only if the task's files include src/**.rs)
     cargo test --test <name>                (for each tests/<name>.rs among the task's files)
   No semaphore, no CARGO_INCREMENTAL, no job or codegen-unit limits.
   On 'No space left on device': cargo clean -p rust-bevy-rpg, then re-run.

3. Fix failures, at most ${cap} rounds of fix -> commit -> re-run step 2.
   In the task's files, fix anything. In ANY OTHER file, fix an error only when
   the task's own diff caused it, which here means all of:
     - its code is one of:${OOS_CODES% }
     - it names an identifier (enum or variant, type, function, method, field,
       trait item) that appears on a + or - line of
       git diff \$BASE ${head} -- '*.rs'
     - the file is an existing .rs file
   Typical: match arms for variants the task added (E0004); a call site updated
   to a signature the task changed (E0061/E0308); a field the task added,
   supplied in a struct literal (E0063). Edit only at uses of that identifier:
   every hunk (3 lines of context) must mention it and may remove at most
   ${OOS_MAX_REMOVED_PER_HUNK} lines. If unsure whether the error also exists at \$BASE, check out
   \$BASE in a separate worktree and run the clippy gate there; failing there too
   means it is not this task's. Anything else outside the task's files is not
   yours: do not edit it; finish with result: FAIL and name it. Declare every
   out-of-scope file you edit in the verdict (step 7) — an undeclared one gets
   all of your work rejected. Fix causes, not symptoms: adding
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
out-of-scope: <path> <code> <identifier> -- <compiler message>
                                      (one line per file and identifier you fixed
                                       outside the task's files; none -> omit)
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
  WAKE_ISSUE="${3:-$task}"
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
    wake; return 0
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
  wake
}

# OUT-OF-SCOPE FIXES. Scope exists so one task's verify cannot rewrite another
# task's work or "fix" breakage that is already on main. An error the task's own
# diff caused is neither: a task that adds enum variants breaks every exhaustive
# match over that enum, wherever it lives, and bouncing that to the operator costs
# a full pipeline cycle for a mechanical fix. So such an edit is admitted — but
# only in a shape this box can check without compiling, because acceptance must
# stay cheap and the VM is untrusted:
#
#   - Declared. The verdict carries `out-of-scope: <path> <code> <identifier>`
#     for it; an undeclared path is rejected, so nothing reaches the tree unnamed.
#   - A qualifying error class. Each of these codes is the downstream half of a
#     change to a definition — a variant, field, signature, name or trait item.
#     Lints and every other code stay out: they are not tied to a definition the
#     diff changed, which is exactly the pre-existing breakage scope excludes.
#   - Tied to the diff. The identifier must sit on a +/- line of the task's own
#     Rust diff (base..launched head). That is the mechanical stand-in for
#     "compiles at base, fails at head": an error naming something the task did
#     not change cannot have been caused by it.
#   - Local to uses of it. Every hunk of the edit, with 3 lines of context, must
#     mention a declared identifier, and may remove at most
#     OOS_MAX_REMOVED_PER_HUNK lines. Adding match arms removes nothing; a call
#     site rewritten to a new signature removes a line or two (rustfmt reflow
#     included). Rewriting unrelated logic under the cover of a declaration
#     does neither.
#   - An existing .rs file. Compile errors live in Rust sources; a new file
#     cannot have one, and deleting files is refused for everything.
#
# What this does NOT bound: lines added inside a hunk that mentions the
# identifier. That residue is why accepted out-of-scope edits are listed in the
# PR body for the operator, whose merge stays the final gate.
OOS_CODES=" E0004 E0023 E0026 E0027 E0046 E0050 E0053 E0061 E0063 E0308 E0412 E0425 E0432 E0433 E0560 E0599 E0609 "
OOS_MAX_REMOVED_PER_HUNK=3
# An identifier that matches everything ties nothing to the diff.
RUST_KEYWORDS=" as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while "

# Prints why the edit to $1 is not admissible and returns 1, or returns 0.
check_out_of_scope() {
  local f="$1" base="$2" lease="$3" work="$4" body="$5" ids="" path code id rest
  case "$f" in *.rs) ;; *) echo "not a Rust file"; return 1 ;; esac
  git cat-file -e "$lease:$f" 2>/dev/null || { echo "not present at the launched head"; return 1; }
  while read -r path code id rest; do
    [ "$path" = "$f" ] || continue
    case "$OOS_CODES" in *" $code "*) ;; *) echo "code '$code' does not qualify"; return 1 ;; esac
    printf '%s\n' "$id" | grep -qxE '[A-Za-z_][A-Za-z0-9_]+' || { echo "'$id' is not an identifier"; return 1; }
    case "$RUST_KEYWORDS" in *" $id "*) echo "'$id' is a keyword"; return 1 ;; esac
    git diff -U0 "$base" "$lease" -- '*.rs' | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' \
      | grep -qw -- "$id" || { echo "'$id' is not on a line the task's diff changed"; return 1; }
    ids="$ids $id"
  done < <(printf '%s\n' "$body" | sed -n 's/^out-of-scope: *//p')
  [ -n "$ids" ] || { echo "undeclared"; return 1; }
  git diff -U3 "$lease" "$work" -- "$f" | awk -v ids="$ids" -v max="$OOS_MAX_REMOVED_PER_HUNK" '
    function hit(s,   i) {
      for (i = 1; i <= n; i++) if (s ~ ("(^|[^A-Za-z0-9_])" w[i] "([^A-Za-z0-9_]|$)")) return 1
      return 0
    }
    function done_hunk() {
      if (bad) return
      if (!seen) { print "a hunk mentions no declared identifier"; bad = 1 }
      else if (rm > max) { print "a hunk removes " rm " lines (max " max ")"; bad = 1 }
    }
    BEGIN { n = split(ids, w, " ") }
    /^@@/ { if (in_hunk) done_hunk(); in_hunk = 1; seen = 0; rm = 0; next }
    !in_hunk { next }
    { if (hit(substr($0, 2))) seen = 1; if (substr($0, 1, 1) == "-") rm++ }
    END { if (in_hunk) done_hunk(); exit bad }'
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
  git merge-base --is-ancestor "$lease" "$work" || reject "cloud commits do not descend from the launched head"

  # Scope: every file the VM changed must be one of the task's files, a
  # regenerated schema, or a declared out-of-scope fix the task's own diff
  # forced (`check_out_of_scope`).
  local task_files body why
  task_files="$(git diff --name-only "$base" "$lease")"
  body="$(cat "$STATE_DIR/$TASK.cloud.verdict" 2>/dev/null)"
  bad=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in assets/schemas/*) continue ;; esac
    printf '%s\n' "$task_files" | grep -qxF -- "$f" && continue
    why="$(check_out_of_scope "$f" "$base" "$lease" "$work" "$body")" || bad="$bad $f ($why)"
  done < <(git diff --name-only "$lease" "$work")
  [ -z "$bad" ] || reject "cloud commits touch files outside the task:$bad"

  # Uncommitted edits are refused only where the cloud commits land. A guard run
  # by the pre-push hook during offload can rewrite a tracked baseline file, so
  # "any dirt" rejected every cloud fix; dirt elsewhere survives the fast-forward
  # and the `reset --keep` rollback untouched.
  bad=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    git diff --name-only "$lease" "$work" | grep -qxF -- "$f" && bad="$bad $f"
  done < <(git status --porcelain | cut -c4-)
  [ -z "$bad" ] || reject "uncommitted edits to files the cloud commits change:$bad"

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
      git reset -q --keep "$lease"
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
  local task="${1:?task id}" branch="${2:?branch}" verify_task="${3:-$1}" open
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
  # --no-verify: the pre-push hook runs the full guard suite, minutes under build
  # load, and the Architect's run ends and kills this command mid-hook — after
  # `.base` is written, before the push — leaving no sentinel and a guard-rewritten
  # baseline that makes the next offload refuse as uncommitted. The push is only
  # the VM's input; the VM runs the suite and acceptance re-runs it on this box.
  git push -q --no-verify --force-with-lease -u origin "HEAD:$branch" || { echo "push of $branch failed — run locally"; exit 1; }
  rm -f "$STATE_DIR/$task.exit" "$STATE_DIR/$task.cloud.head" "$STATE_DIR/$task.cloud.verdict"
  setsid "$0" watch "$task" "$branch" "$verify_task" >/dev/null 2>&1 < /dev/null &
  echo "offloaded $task: $(tail -1 "$STATE_DIR/pace.log" 2>/dev/null)"
}

# Mirrors the local wrapper's callback so a verdict does not wait for the next
# scheduled wake. The payload names the Verify task: a wake without one is bound
# by the server to whatever task this agent's resumed session last touched, so
# the run lands on a finished task, reports nothing to do, and the green result
# sits unlanded until the next Coordinator fire.
wake() {
  [ -n "${PAPERCLIP_API_URL:-}" ] && [ -n "${PAPERCLIP_AGENT_ID:-}" ] || return 0
  curl -fsS -X POST "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID/wakeup" \
    ${PAPERCLIP_API_KEY:+-H "Authorization: Bearer $PAPERCLIP_API_KEY"} \
    -H 'Content-Type: application/json' \
    -d "{\"source\":\"automation\",\"triggerDetail\":\"callback\",\"reason\":\"verify-sentinel-ready\",\"payload\":{\"issueIdentifier\":\"${WAKE_ISSUE}\"}}" \
    >/dev/null 2>&1 || true
}

case "${1:-}" in
  launch) shift; cmd_launch "$@" ;;
  poll)   shift; cmd_poll   "$@" ;;
  watch)  shift; cmd_watch  "$@" ;;
  offload) shift; cmd_offload "$@" ;;
  accept)  shift; accept_cloud_work "$@" ;;
  *) printf 'usage: %s offload <task-id> <branch> [verify-task-id] | launch <task-id> <branch> | poll <task-id> | watch <task-id> <branch>\n' "${0##*/}" >&2; exit 2 ;;
esac
