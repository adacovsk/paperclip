<p align="center">
  <img src="doc/assets/header.png" alt="Paperclip" width="720" />
</p>

<p align="center">
  <a href="#quickstart"><strong>Quickstart</strong></a> &middot;
  <a href="agents/README.md"><strong>The pipeline</strong></a> &middot;
  <a href="doc/"><strong>Docs</strong></a> &middot;
  <a href="https://github.com/paperclipai/paperclip"><strong>Upstream</strong></a>
</p>

<p align="center">
  <a href="https://github.com/adacovsk/paperclip/blob/master/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License" /></a>
  <a href="https://github.com/paperclipai/paperclip"><img src="https://img.shields.io/badge/fork%20of-paperclipai%2Fpaperclip-lightgrey" alt="Fork of paperclipai/paperclip" /></a>
</p>

# Paperclip, the pipeline fork

This is `adacovsk/paperclip`, a fork of
[`paperclipai/paperclip`](https://github.com/paperclipai/paperclip) that has become
a separate codebase. Upstream is building a general platform for AI companies, with
runners, sandboxes, MCP connections, apps and catalogs. This fork kept Paperclip's
control plane and pointed it at one job: running an unattended software pipeline
against a real repository, around the clock, with one human who reviews and merges.

Most of the differences come from operating that pipeline and fixing whatever broke
it. The server and UI changes harden the run engine, so that runs don't wedge,
livelock or report themselves finished when they aren't. The [`agents/`](agents/)
directory holds the pipeline itself: eight role specs and the scripts that run
between model runs.

The two codebases share no history after the fork point, and nothing is merged in
either direction. **File issues and PRs here, not upstream.** Upstream's docs site,
Discord, npm package and roadmap all describe upstream's build.

## What Paperclip is

Paperclip is a Node.js server and React UI that orchestrates a team of AI agents.
Agents belong to a company. They have roles, a reporting line and a budget, and they
work on tickets. A ticket is checked out atomically to one assignee, every comment
and status change is logged, and agents wake on a schedule (a *routine*), on
assignment, or when another agent's stage completes. The operator sees everything
from one dashboard and can pause, reassign or override any of it.

All of upstream's core model is still here and still works:

- multiple companies with isolated data
- org charts
- per-agent budgets and cost tracking
- approvals and governance
- routines and triggers
- company import/export
- the plugin system
- the mobile layout
- the adapters: Claude Code, Codex, Cursor, Gemini, OpenCode, Pi, Hermes, OpenClaw gateway, plus plain process and HTTP agents

## What this fork changes

### The pipeline

[`agents/README.md`](agents/README.md) is the cross-role contract. It records, for
each role, who may edit what, who runs the build, who pushes, who opens a PR, and
who merges. Each role's full procedure is in `agents/<role>/INSTRUCTIONS.md`.

```
Operator          human; sets direction, reviews and merges task PRs
  Planner         on demand      owns the roadmap; files backlog; triages GitHub issues
  Coordinator     every 30 min   promotes backlog, allocates worktrees, sweeps landings and merges
  Dispatcher      every 30 min   no model; advances finished stages, routes build results, lands green builds
    Worker        on assignment  implements the task on task/<id>; never pushes
    Reviewer      on assignment  correctness review of the Worker's diff; commits fixes
    Architect     on assignment  the build gate: builds, fixes what its task broke, lands
  Tester          nightly        clippy and the full test suite on main; files failures as issues
  Facilitator     nightly        pipeline health; missed wakes, stuck tasks, stale branches
```

Builds are the bottleneck, and most of `agents/architect/` exists to manage them:

- **`cargo-sem.sh`** is a FIFO build semaphore. Its slot count comes from cores and
  memory, and it has an express lane and a per-worktree lock. Builds run detached
  and report back through sentinel files, so a model run never sits waiting on a
  compile.
- **The cloud lane** (`cloud-verify.sh`, `cloud-pace.py`) sends builds to Claude
  Code cloud sessions. It stays open while account usage is under its ceilings. The
  VM can only publish to a `cloud-verify/<task>/<sha>` ref, and this machine decides
  whether to accept the work. It accepts only commits that descend from the
  launched head, stay inside the task's files, add no lint suppressions and pass
  the local gate.
- **Landing without a model.** For a green build, the Dispatcher runs `land.sh` in
  the background: freshness check, push (the pre-push hook is the landing gate),
  PR body, PR. A model is woken only when something needs judgment.
- **The freshness check** (`freshness_interaction.py`) decides whether `main`
  moving under a green branch means a rebuild. It checks whether the two changes
  actually interact: build-wide files, a shared file, a shared data set, the code
  that reads that data, or a shared symbol. A green branch that main's advance
  doesn't reach goes straight to landing.

### Run-engine hardening

Each of these is a failure the pipeline hit and this fork then closed:

| | |
| --- | --- |
| **No wedged queues** | A per-run watchdog kills hung adapters. `maxConcurrentRuns` is enforced by a per-agent Postgres advisory lock instead of in-process state. |
| **No chain-wake livelock** | The server won't re-wake an agent on a task it already holds. It won't wake a parent that is waiting on someone else's stage, wake an agent on its own comment or on a hold comment, or loop without progress. |
| **Honest completion** | A skill-less agent's task is marked done only when its branch has merged into the base ref, behind a fail-closed check that a PR exists on origin. Pushing is not finishing. |
| **Blocked means blocked** | A task someone stopped stays where it was put. Completion cascades don't promote `blocked`, `backlog` or `cancelled` tasks. |
| **Idempotent subtasks** | Subtask creation takes a `dedupeKey`, backed by a unique index, so two racing sweeps can't file the same Review twice. |
| **Stage-aware wakes** | Stage-completion wakes go to the Dispatcher, which advances the board without a model, with the Coordinator as fallback. |
| **Usage limits are waits** | A provider usage limit pauses the run until reset instead of counting as a failure to retry. |
| **Builds outlive the run** | Long compiles run detached, keep a live run so the queue stays honest, and are torn down when their task dies. Orphaned child processes are swept at startup. |
| **Diagnosable failures** | A run killed by server shutdown says so, so `process_lost` is no longer mistaken for OOM. |
| **Bounded history** | Run, issue, comment and activity lists are paginated and run history is pruned, so the dashboard stays fast on a long-running instance. |

### Operator UI

- The Inbox lists only what has gone wrong.
- The sidebar shows live run dots per agent.
- Transcripts are newest-first with collapsible invocations.
- The kanban columns collapse.
- The dashboard shows queue depth.
- `/sessions/summary` reports per-agent session reuse and token use.
- "Board" is renamed "operator" throughout the code, API, UI and database.

### Security

- Agent-facing routes are company-scoped end to end: import, approvals, activity and heartbeat.
- Bearer tokens are redacted from logs.
- The hardcoded JWT secret fallback is removed.
- `agents:read_config` adds a read-only view of agent configuration.
- `pnpm check:agent-privacy` keeps private references out of `agents/**`, which is public and ships in the npm package.

### Removed

- **The provider quota-windows subsystem.** Weekly quota is read where the pipeline actually uses it: `cloud-pace.py` and cost tracking.
- **Hiding issues.** The API refuses `hiddenAt`.
- **The CEO onboarding bundle.** New agents get the default instructions.

## Quickstart

Run it from source. `npx paperclipai` installs **upstream's** published package, not
this fork.

```bash
git clone https://github.com/adacovsk/paperclip.git
cd paperclip
pnpm install
pnpm dev
```

This serves the API and UI at `http://localhost:3100`, with an embedded PostgreSQL
under `~/.paperclip/instances/default/db/`. No other setup is needed.

> **Requirements:** Node.js 20+ (CI uses the version in `.nvmrc`), pnpm 9.15+

**To run a live pipeline, use a built server, not `pnpm dev`.** `pnpm dev` runs the
server under `tsx watch`, and every reload kills every in-flight agent run.

```bash
pnpm build
pnpm --filter @paperclipai/server start
```

To use the pipeline itself, read [`agents/README.md`](agents/README.md). The role
specs read the target repository's path from `PAPERCLIP_PROJECT` and assume a
cargo build, so adapting them to another stack means editing the Architect's and
the Tester's build commands.

## Development

```bash
pnpm dev                    # API + UI, watch mode
pnpm dev:once               # same, without file watching
pnpm build                  # build every package
pnpm -r typecheck           # type-check every package
pnpm test:run               # Vitest
pnpm test:e2e               # Playwright
pnpm db:generate            # generate a migration after a schema edit
pnpm db:migrate             # apply migrations
pnpm check:agent-privacy    # no private references in agents/**
pnpm check:agent-rationale  # every rationale link and quote in agents/** resolves
pnpm paperclipai doctor     # instance health check (--repair to fix)
```

A change is done when `pnpm -r typecheck && pnpm test:run && pnpm build` passes.
That is also what `pr.yml` runs on every PR to `master`, after a policy job that
rejects lockfile-only edits. [`CLAUDE.md`](CLAUDE.md) has the repo's rules, and
[`doc/DEVELOPING.md`](doc/DEVELOPING.md) the full development guide.

When using `gh` from this checkout, always pass `--repo adacovsk/paperclip`. A bare
`gh` resolves to upstream and will open your PR there.

## License

MIT. Portions &copy; the upstream Paperclip authors; fork changes &copy; 2026 adacovsk.
