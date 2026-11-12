# AGENTS.md

Paperclip = control plane for an unattended, multi-agent software pipeline. Node.js server + React UI.

**The repo's rules live in [`CLAUDE.md`](CLAUDE.md), and it is authoritative.** Read its Rules section before any change; this file only orients. Keeping the rules in one file is deliberate: a second copy here drifted until the two contradicted each other.

## Read First

1. `CLAUDE.md` (rules, commands, done-when)
2. `agents/README.md` (the pipeline's cross-role contract)
3. `doc/SPEC-implementation.md` (V1 build contract)
4. `doc/DEVELOPING.md`, `doc/DATABASE.md`

## Repo Map

| Path | Purpose |
|------|---------|
| `server/src/routes/` | REST API endpoints |
| `server/src/services/` | Business logic |
| `ui/src/pages/` | React operator UI (React 19, Tailwind v4, shadcn/ui) |
| `packages/db/src/schema/` | Drizzle ORM table definitions |
| `packages/shared/` | Shared types, constants, validators |
| `packages/adapters/` | Agent runtime adapters (claude-local, codex-local, cursor-local, etc.) |
| `skills/` | Runtime-injected agent skills |
| `agents/` | The pipeline: role specs and the scripts between model runs. **Public**: see `CLAUDE.md` rule 9 |
| `cli/` | `paperclipai` CLI client |
| `doc/` | Product and ops docs |
| `docs/` | Mintlify docs site; plans go in `docs/plans/YYYY-MM-DD-slug.md` |

## Dev

```sh
pnpm install && pnpm dev  # API + UI at http://localhost:3100, embedded Postgres auto-starts
```

Reset: `rm -rf ~/.paperclip/instances/default/db && pnpm dev`

## Done When

`pnpm -r typecheck && pnpm test:run && pnpm build` all pass, contracts are synced across db/shared/server/ui, and docs are updated if behavior changed.
