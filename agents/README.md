# Pipeline Roles

This is the cross-role contract for the agent pipeline: who does what, so the role
specs can't drift apart. Each role's full procedure is in `{role}/INSTRUCTIONS.md`.
The reasons behind individual rules are in `{role}/rationale/`. The Dispatcher has
no INSTRUCTIONS file because it runs no model; its contract is the docstring at the
top of `dispatcher/dispatch.py`. <!-- privacy-ok: the pipeline's own scripts, not project source -->

The pipeline runs against one target repository, read from `PAPERCLIP_PROJECT`.
Task work happens in per-task worktrees under
`$PAPERCLIP_PROJECT/.paperclip/worktrees/{id}`, each on branch `task/{id}`.

## Roles

```
Operator (human: sets direction, reviews and merges task PRs)
  Planner       — on assignment   — owns the roadmap; files backlog; triages GitHub issues; tunes agent configs
  Coordinator   — :15 and :45     — promotes backlog, allocates worktrees, advances what needs judgment, landing and merge sweeps
  Dispatcher    — :10 and :40, and every stage-completion or sentinel wake — no model; advances the board mechanically
    Worker      — on assignment   — implements the task; commits to task/{id}; never pushes
    Reviewer    — on assignment   — correctness review of the Worker's diff; commits fixes; never pushes
    Architect   — on assignment   — the build gate: builds, fixes what its task broke, lands
  Tester        — 02:00           — clippy -D warnings (both feature sets) and every test target on origin/main
  Facilitator   — 20:45           — pipeline health; missed wakes, stuck tasks, stale branches
```

Times are America/Denver. The routine triggers in Paperclip are the source of
truth (`PATCH /api/routine-triggers/{id}`), and the target project's `CLAUDE.md`
records why each is set where it is. The Facilitator's nightly fire runs just after
the weekly usage-limit reset, because the slot before the reset has the least quota
left in the week.

**How each role is woken:**

- **Worker, Reviewer and Architect** have no routine. Setting the assignee is the
  wake (`wakeOnDemand`). A comment never re-fires one. To re-dispatch, toggle the
  assignee through `null`.
- **The Planner** is woken by assignment only. Its demand signal is the
  Coordinator's `Backlog low` task.
- **The Dispatcher** has a routine. The server also routes every stage-completion
  wake to the agent with role `dispatcher`, falling back to the Coordinator only
  while the Dispatcher is paused, terminated or awaiting approval.
  `architect/sentinel-callback.sh` wakes the Dispatcher when a build result is
  readable.
- **The Coordinator** has a routine. Between fires, the Dispatcher wakes it with a
  `dispatcher_handoff` wake listing only the tasks that need judgment.
- **The Tester's** routine fire launches `tester/run-nightly.sh` detached and exits.
  The script wakes it a second time when the result is ready.

## Matrix: who does what

| Action | Worker | Reviewer | Architect | Dispatcher | Coordinator | Planner | Tester | Facilitator |
|---|---|---|---|---|---|---|---|---|
| Edit project code | ✓ | ✓ | ✓ ¹ | — | — | — | — | — |
| Edit the roadmap | — | — | — | — | — | ✓ ² | — | — |
| Edit subsystem `CLAUDE.md` | — | — | — | — | — | ✓ | — | — |
| Edit `agents/**` specs | — | — | — | — | — | ✓ ³ | — | files a followup |
| Run cargo | — | — | ✓ | via scripts ⁴ | — | — | ✓ ⁵ | — |
| Commit to `task/{id}` | ✓ | ✓ | ✓ | — | merge commit only ⁶ | — | — | — |
| Push `task/{id}` and open its PR | — | — | ✓ | ✓ (`land.sh`) | ✓ (landing sweep) | — | — | — |
| Merge a task PR | — | — | — | — | — | — | — | — |
| Merge `planner/roadmap` | — | — | — | — | — | ✓ | — | — |
| Delete a remote `task/*` branch | — | — | — | — | ✓ (after merge) | — | — | ✓ ⁷ |
| `git worktree add` / `remove` | — | — | — | ✓ (`promote.py`) | ✓ | own worktree | own worktree | — | <!-- privacy-ok: the pipeline's own scripts, not project source -->
| Create Paperclip tasks | — | files issues | — | ✓ ⁸ | ✓ | ✓ (backlog) | — | ✓ (followups) |
| PATCH status or assignee | — | own task | — ⁹ | any, mechanically | any | own task | own task | any, to unstick |
| Paperclip API | none | `paperclip` skill | none | direct HTTP | `paperclip` skill | `paperclip` skill | `paperclip` skill | `paperclip` skill |
| `gh` | — | — | ✓ | ✓ | ✓ | ✓ | issues only | ✓ |
| Network | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Only the operator merges task PRs, and nobody commits to `main` directly.

1. Only to fix errors its own task caused, or anything on `main` for a main-repair task.
2. The roadmap has exactly one writer, the `planner/roadmap` branch. The target project's guards fail any task branch, or any other `planner/*` branch, that touches it. The Planner merges its own roadmap PR once the landing gate passes, because the Coordinator promotes from `main` and an unmerged roadmap restocks nothing. This is the only self-merge, and it never extends to a branch carrying code.
3. Only through its own `planner/agents` worktree of this repo. The operator merges that PR; the Planner never self-merges it.
4. The Dispatcher runs no cargo itself. It starts builds through `architect/relaunch-verify.sh` (cloud launches) and lands through `architect/land.sh`, whose push runs the pre-push hook.
5. Only through `tester/run-nightly.sh`, against its own detached worktree of `origin/main`, under `cargo-sem.sh`. It never builds a task branch.
6. The merge commit for a diverged PR in its landing sweep, plus the commits `coordinator/train-sync.sh` and `coordinator/merge-sweep.py` make. <!-- privacy-ok: the pipeline's own scripts, not project source -->
7. Only branches that are already merged, or have no diff against `main`.
8. Review and Verify subtasks, rebase tasks, one main-repair task when several verifies see the same red `main`, and the cancellation of tasks filed twice.
9. The Architect has no API access. It escalates by ending its run with `PAPERCLIP-ESCALATE: <reason>`, which the server turns into `blocked`.

## Task lifecycle

```
backlog, unassigned                     ← Planner files it from the roadmap's active fronts on main
  → todo, Worker assigned               ← promote.py / Coordinator: worktree first, assignee last (the assignee write is the wake) <!-- privacy-ok: the pipeline's own scripts, not project source -->
  → blocked, unassigned, "Held: …"      ← when it can't be dispatched yet
  → in_progress                         ← server, on the Worker's wake
  → in_review                           ← server, when the Worker exits
      Review subtask (in_review, Reviewer)   ← Dispatcher
        → done                               ← Reviewer
      Verify subtask (in_review, Architect)  ← Dispatcher, for needs-build work or data changes
        → build: cloud lane, or local chain under cargo-sem.sh
        → {parent}.exit sentinel → sentinel-callback.sh wakes the Dispatcher
        → green: land.sh in the background, or the Architect's Landing block, or the Coordinator's landing sweep
             push (pre-push hook is the gate) → PR → {parent}.landed
        → Verify done once the open PR carries the landed head
  → operator merges the PR
  → done                                ← merge-sweep.py, gated on every branch commit being on origin/main; reaps the build, removes worktree and branches <!-- privacy-ok: the pipeline's own scripts, not project source -->
```

States are `backlog`, `todo`, `in_progress`, `in_review`, `blocked`, `done` and
`cancelled`. A closed, unmerged PR is the operator's decision, and the Coordinator
treats it as one.

**Holds.** A task that can't be dispatched yet is `blocked` with a null assignee,
written in the same PATCH as a `Held:` comment that names what releases it:

- `Held: until <id> merges`
- `Held: until <id> opens its PR`
- `Held: planner` — not `blocked`: `todo`, assigned to the Planner, whose only wake is that assignment
- `Held: operator` — paperclip source fixes, rules/IP rulings, money/credentials/destructive remote changes only
- `Held: worktree allocation failed`

The Dispatcher releases the first two once their condition holds, hands a
`blocked` `Held: planner` task to the Planner, and never
re-releases a hold the Coordinator wrote back. `dispatcher/hold_of_record.py` prints <!-- privacy-ok: the pipeline's own scripts, not project source -->
the hold currently in force.

**Build results** are sentinel files in `~/.cache/paperclip-verify/`, keyed by the
parent task id. In `{parent}.exit`:

| Code | Meaning |
|---|---|
| `0` | green |
| `1` | red |
| `64` | `cargo-sem.sh` refused a chained cargo call |
| `75` | the worktree lock timed out |
| `94` | superseded: the work is already on `main` |
| `95` | the cloud result was rejected at the trust boundary |
| `96` | environment fault |
| `97` | worktree missing |
| `98` | the base sync failed |
| `99` | inconclusive |
| `100` | the build was reaped |
| `137` | out of memory |

Each code has a rationale file under `architect/rationale/`.

**The Dispatcher acts on these without a model:**

- it relaunches a first `99` or `75`
- it resumes a dead cloud watcher
- it rebuilds when the freshness check says `main`'s advance reaches the branch
- it lands a green cloud build with `land.sh`, at most `DISPATCH_LAND_MAX_RUNNING` at a time

It wakes the Architect once per sentinel for anything else.

## Builds

- **One semaphore.** Every cargo call goes through `architect/cargo-sem.sh`, a FIFO
  slot semaphore. Its slot count is `min(physical cores − 1, memory slots)`, unless
  `CARGO_SEM_SLOTS` is set, and it publishes the ceiling to `/tmp/cargo-sem.slots`.
  The Architect's `maxConcurrentRuns` is deliberately higher than the slot count,
  so model work (reading errors, fixing, committing) overlaps the builds. To add
  build parallelism, raise the slots, not the run count.
- **Detached, never waited on.** Builds run detached and write a sentinel when they
  finish. No model run polls a build.
- **The cloud lane** is on when `ARCHITECT_CLOUD_LANE=1` is set on the Architect.
  It is open while `architect/cloud-pace.py` prints `1`, which means session and <!-- privacy-ok: the pipeline's own scripts, not project source -->
  weekly usage are under their ceilings; an unreadable meter counts as closed. The
  VM publishes only to `cloud-verify/<task>/<sha>`. This box accepts the work only
  if it:
  - descends from the launched head
  - stays inside the task's files or generated schemas
  - adds no suppressions and deletes nothing
  - passes the local gate

  The VM never pushes a task branch or opens a PR.
- **Freshness.** When `main` moves under a green branch,
  `architect/freshness_interaction.py` decides whether to rebuild. It rebuilds only <!-- privacy-ok: the pipeline's own scripts, not project source -->
  if the two changes interact through a build-wide file, a shared file, a shared
  data set, the code that reads that data, or a shared symbol. Any error counts as
  "rebuild".
- **Worker and Reviewer concurrency** is set by `coordinator/pace-scale.py --apply` <!-- privacy-ok: the pipeline's own scripts, not project source -->
  on every Coordinator fire. Never set it by hand.

## Skills and permissions

| Role | Adapter | Skills | `dangerouslySkipPermissions` |
|---|---|---|---|
| Worker | `claude_local` | none | true |
| Reviewer | `claude_local` | `paperclip` | true |
| Architect | `claude_local` | none | true |
| Coordinator | `claude_local` | `paperclip`, `paperclip-create-agent` | true |
| Planner | `claude_local` | `paperclip` | true |
| Facilitator | `claude_local` | `paperclip` | true |
| Tester | `claude_local` | `paperclip` | true |
| Dispatcher | `process` (`python3 dispatch.py`) | n/a | n/a | <!-- privacy-ok: the pipeline's own scripts, not project source -->

There is one agent per role; concurrency comes from `maxConcurrentRuns`. Workers
have no skills because the adapter puts the task into their prompt, and
`PAPERCLIP_API_URL`/`PAPERCLIP_API_KEY` are injected only for agents that hold the
`paperclip` skill.

Every model role runs with skip-permissions, the Worker included. A headless run
that raises a permission prompt stalls until it times out and the task fails, and
that is true whether or not the agent holds a skill. Sandboxing the Worker would be
a change to how the pipeline runs, not a correction to this table.

## Rules for every role

- Never commit directly to `main`, and never merge a task PR.
- Never force-push, and never skip git hooks. `architect/cloud-verify.sh` has the
  only exceptions, and both are leased on the head this box launched:
  - The offload push is `--no-verify`, because it is only the VM's input. The VM
    runs the guards, and acceptance re-runs them here.
  - A resolve-mode result is published with `--force-with-lease`, because it
    rewrites the branch.
- Run cargo only as the matrix allows.
- Never edit another role's `INSTRUCTIONS.md`. The Planner edits them through its own worktree; everyone else files a followup.
- No raw `curl` against the Paperclip API from a model role. Use the `paperclip` skill.
- Pair every status PATCH with a comment saying why. Never revert a block someone else wrote, except to release a `Held:` line whose condition has been met.
- "Landed" means merged into `origin/main`, checked with `git merge-base --is-ancestor`. A pushed branch is not landed.
- A claim that something doesn't exist must cite `origin/main`, not the task branch.

## Authoring these specs

- **Reference another section or step by name, never by number.** Write
  "Coordinator's landing sweep", not "Coordinator step 3". Numeric pointers carry
  no instruction, and they rot silently the moment a list is reordered. A numbered
  list that *defines* a procedure keeps its numbers. The exceptions are the stable
  `Step 0` precondition-gate convention, and references into versioned external
  specs.
- **No private references.** This directory is public and ships in the npm
  package. Don't write tracker ids, PR or issue numbers from the target project,
  its repository name, or its module filenames. Keep the lesson and drop the
  identifier. `pnpm check:agent-privacy` enforces this by shape. A line that is
  genuinely generic opts out with `<!-- privacy-ok: why -->`.
- **Rules go in INSTRUCTIONS; reasons go in rationale.** Each rationale file quotes
  the rule it justifies under `**Justifies:**`. `pnpm check:agent-rationale` fails
  on a broken link, an orphan file, or a quote that no longer appears in the
  INSTRUCTIONS.
- **Check ancestry with `git merge-base --is-ancestor`.** `git branch --contains`
  with a remote ref as its pattern matches only local branch names, so it always
  comes back empty. `pnpm check:agent-git` fails on that shape.
