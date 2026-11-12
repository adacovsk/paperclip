# Contributing

Paperclip has one operator, who reviews and merges every PR, and an agent pipeline that
opens many of them. The rules below apply to both. [`CLAUDE.md`](CLAUDE.md) holds the
full rule set.

## Where to send it

Open issues and PRs against **`adacovsk/paperclip`**, base branch `master`. This
codebase started from `paperclipai/paperclip` but is a separate project now, and
nothing moves between the two. If your clone has a remote pointing at that repo, pass
`--repo adacovsk/paperclip` to every `gh` command, or run
`gh repo set-default adacovsk/paperclip` once. Otherwise `gh` can silently open the PR
on the wrong repo.

## Before you open a PR

```bash
pnpm -r typecheck && pnpm test:run && pnpm build
```

`pr.yml` runs the same three on every PR, after a policy job. Also check these:

- **Lockfile.** Commit `pnpm-lock.yaml` only together with the manifest change that
  moved it. A lockfile-only edit is rejected; regenerate it with
  `gh workflow run refresh-lockfile.yml --repo adacovsk/paperclip`. Never hand-resolve
  a lockfile conflict.
- **Schema changes** go through every layer: `packages/db` → `packages/shared` →
  `server` → `ui`, with a migration from `pnpm db:generate`.
- **`agents/**` is public.** The pipeline runs against a private repository, so
  nothing from it goes in: no tracker ids, PR numbers, repo name or source filenames.
  Keep the lesson and drop the pointer. Run `pnpm check:agent-privacy` and
  `pnpm check:agent-rationale` before pushing any `agents/**` edit.
- **Docs** are updated in the same PR when behavior changes.

## Shape of a PR

- One PR = one logical change. Small and targeted merges fastest.
- For a large or cross-cutting change, open a draft PR describing the problem and
  approach first.
- Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md). It starts with a
  **thinking path**, 5–8 steps from what Paperclip is down to this change:

  > - Paperclip runs an unattended agent pipeline against a real repository
  > - Agents wake on a schedule, on assignment, or when another agent's stage completes
  > - A stage-completion wake could re-wake an agent on a task it already held
  > - That looped without progress and burned the run budget
  > - This pull request refuses a wake on a task the agent already holds
  > - The benefit is that a finished stage advances the board instead of spinning

- Say how a reviewer can verify it. For UI changes, include before/after screenshots.
- When closing a defect, state which mechanism you verified, not only that the symptom
  is gone (`CLAUDE.md` rule 10).
