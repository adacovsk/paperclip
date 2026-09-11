# CLAUDE.md

Paperclip = open-source control plane for autonomous AI companies. Node.js server + React UI. Orchestrates agent teams with org charts, tasks, budgets, heartbeats, governance.

## Repo

| Path | What |
|------|------|
| `server/src/routes/` | Express REST API endpoints |
| `server/src/services/` | Business logic |
| `ui/src/pages/` | React 19 + Tailwind v4 + shadcn/ui operator UI |
| `packages/db/src/schema/` | Drizzle ORM tables (PostgreSQL) |
| `packages/shared/` | Shared TS types, constants, validators |
| `packages/adapters/` | Agent adapters: claude-local, codex-local, cursor-local, pi-local, gemini-local, opencode-local, openclaw-gateway |
| `packages/adapter-utils/` | Shared adapter utilities |
| `skills/` | Runtime-injected agent skills (paperclip, create-agent, create-plugin, para-memory) |
| `cli/` | `paperclipai` CLI |
| `doc/` | Product/ops docs |

## Commands

```sh
pnpm dev                  # Server + UI at http://localhost:3100 (embedded Postgres auto-starts)
pnpm build                # Build all
pnpm -r typecheck         # TS check all packages
pnpm test:run             # Vitest
pnpm test:e2e             # Playwright E2E
pnpm db:generate          # Generate migration after schema edits
pnpm paperclipai doctor   # Health check (--repair to fix)
```

Data: `~/.paperclip/instances/default/db/`. Reset: `rm -rf` that dir + `pnpm dev`.

**`pnpm dev` runs the server under `tsx watch`, and every reload kills all
in-flight agent runs.** Children are tracked, not detached, so the shutdown
handler SIGTERMs them — editing or merging any watched server file mid-run
discards that run's work (a 12-minute Worker run went this way; the retry
re-pays the whole context load). It is the sole confirmed cause of clustered
`process_lost` — the run record now names the signal, so check for
`the server shut down` in the error before investigating OOM or the SDK.
Serve a live pipeline from a built server (`pnpm build` + `pnpm --filter
@paperclipai/server start`), and keep `pnpm dev` for development where losing
a run is acceptable.

## Stack

Node.js 20+, Express, TypeScript (ES2023/NodeNext), Drizzle ORM, React 19, Vite, Tailwind v4, shadcn/ui, Radix, PGlite (dev) / Postgres (prod), pnpm 9.15+, Vitest, Playwright.

## Rules

1. **Company-scoped.** Every entity belongs to a company. Enforce boundaries in routes/services.
2. **Sync layers.** Schema change -> update `packages/db` -> `packages/shared` -> `server` -> `ui`.
3. **Invariants.** Single-assignee tasks, atomic checkout, approval gates, budget hard-stop, activity logging.
4. **Auth.** Operator = full control. Agents = bearer API keys (hashed, company-scoped). Errors: 400/401/403/404/409/422/500.
5. **DB changes.** Edit schema -> export from index.ts -> `pnpm db:generate` -> `pnpm -r typecheck`.
6. **Modes.** `local_trusted` (loopback, no login) | `authenticated/private` (LAN/Tailscale) | `authenticated/public` (internet).
7. **No lockfile commits *without a manifest reason*.** Commit `pnpm-lock.yaml` only in the same PR as the `package.json` / `pnpm-workspace.yaml` / `.npmrc` change that moved it — that is a dependency bump, and it is allowed. A lockfile-only edit is rejected by `pr.yml`'s `policy` job; CI owns those via `refresh-lockfile.yml` (`gh workflow run refresh-lockfile.yml --repo adacovsk/paperclip`). Never hand-resolve a lockfile conflict — regenerate it. This rule used to read "no lockfile commits" flatly, and the gate implemented it that way, which made *every* dependency change unmergeable in both directions: with the lockfile `policy` rejected it, and without the lockfile `verify`/`e2e` rejected it, since both install with `--frozen-lockfile`.
8. **Never PR onto `paperclipai/paperclip` (upstream).** This fork (`adacovsk/paperclip`, remote `origin`) has diverged from upstream — hundreds of commits each way — so upstream is a *different codebase*, not a merge target. All work integrates into `adacovsk/paperclip:master` (what the local instance and every operator worktree track). **Always pass `--repo adacovsk/paperclip` to every `gh` command** (`pr create`/`merge`/`view`/`repo view`). Bare `gh` resolves this dir to the parent `paperclipai/paperclip` and will *silently open the PR against upstream* (it does not reliably fail — it succeeds against the wrong repo, then shows as CONFLICTING because upstream rewrote the files). If you ever find a PR of ours open on `paperclipai/*`, it was mis-targeted — close it and recreate with `--repo adacovsk/paperclip`. Default branch is `master`.
9. **This repo is PUBLIC; the project it runs against is PRIVATE. Never write private references into `agents/**`.** No tracker ids, no PR/issue numbers from the downstream repo, no repo name, no module filenames from its tree. `agents/` ships in the npm package (there is no `files` field and no `.npmignore`), so anything written there is published.

   **Keep the lesson, drop the pointer.** The incident narration is load-bearing — it is what stops a rule being re-litigated or tidied away — so do not delete it to comply. Rewrite it without the identifiers: *"one task held a build slot 1h40m while ten verifies queued behind three slots"* carries the entire argument. The version naming the task, the PR and the source file adds nothing a public reader can act on and leaks a private tree.

   Enforced by `pnpm check:agent-privacy`. It matches on **shape, never on a list of names** — a denylist of secrets in a public file is a list of secrets, and it is only as good as what someone remembered to add (the first version leaked the names it hid *and* missed four sitting in the docs while it reported clean). So: tracker-id and PR-number shapes, and any project source filename by default. Build machinery is allowed by verb prefix (`check_`, `run_`, `generate_`) because an agent must be able to name the guard that will fail its push; product modules are nouns and fail. The downstream repo name is read from `PAPERCLIP_PROJECT` rather than written down, so that check runs locally and is skipped in CI.

   A genuinely generic or operationally required token opts out per line with `<!-- privacy-ok: why -->`, which documents itself and reveals nothing the same line does not already show. Run it before pushing any `agents/**` edit — prose alone would not have caught the 144 references the guard found on its first run.

10. **Closing a defect: verify the mechanism, not the absence of symptoms.** A fleet scan showing the bad state is nowhere present answers *"is it happening right now"*, which is not the question a defect ticket asks. Read the code path that would produce it and confirm every branch is covered.

   The worked case: a lock-expiry defect was closed on three readings, each individually true — the self-heal exists in the source, the originally-reported issue is clear, and a per-issue GET across every live issue found zero instances. All three held. The defect recurred anyway, because the self-heal only fired for a run that had *left* `queued`/`running`, and the shape that actually recurs is a run stuck **in** `queued` — which nothing expired, since the reaper skips queued by design, the release path fires only on termination, and the resume path runs only at server start. The ticket's own comments described a queued holder twice and the closure did not reconcile them.

   Two habits fall out of that, both cheap. **Read the ticket's own recurrence comments before closing** — a defect filed once and observed four times has four descriptions of the mechanism, and they may not agree with the filing. **State the shape you verified**, so a later reader can tell which branch was checked rather than assuming all of them were. "No live instance" and "the mechanism is covered" are different claims and only the second closes a defect.

## Done When

`pnpm -r typecheck && pnpm test:run && pnpm build` all pass. Contracts synced across all layers. Docs updated if behavior changed.

## Docs

| Doc | Purpose |
|-----|---------|
| `doc/SPEC-implementation.md` | V1 build contract (authoritative) |
| `doc/PRODUCT.md` | Core concepts, design goals |
| `doc/GOAL.md` | Vision |
| `doc/DEVELOPING.md` | Dev setup, worktrees, secrets, CLI |
| `doc/DATABASE.md` | DB modes, backups, secrets |
| `doc/CLI.md` | CLI reference |
| `skills/paperclip/SKILL.md` | Agent heartbeat procedure + API |
| `skills/paperclip/references/api-reference.md` | Full API tables |
