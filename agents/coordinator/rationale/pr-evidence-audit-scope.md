# What the PR-evidence audit is for, and its two known blind spots

**Justifies:** *A backstop, not the primary net: the server's Layer-2 gate* (§PR-evidence audit)

## Why it exists, and why it is now a backstop

Historically the server marked a verify subtask `done` purely on Architect run **exit code**. Any
silent-exit path — Step 0 abort, missing manifest, comment write fail, agent ran with the wrong
cwd — produced a `done` task with no PR and no merge, and the parent could flip `done` behind it
while the code sat stranded in a worktree. Observed: an agent ran from the main checkout (a Step 0
cwd violation), dropped 10 files of edits in the wrong tree, exited cleanly, server marked it done.
Six other tasks hit a different flavour of the same failure and stranded their work ~36h before the
operator pushed and PR'd by hand.

The server's Layer-2 gate (`heartbeat.ts`) now auto-completes a no-skill agent's task to `done`
**only when its branch is confirmed on origin** (fail-closed `ls-remote`); otherwise it holds at
`in_review`. That catches silent exits at the source, so the audit is a backstop. Keep running it:
it still covers cherry-picked-but-not-PR'd work and any residual path the gate cannot see.

## Why the PR lookup is not keyed to the head branch

When the operator recovers stranded work it lands on `op/recover-{identifier}`, not on
`task/{identifier}` — so the head-only lookup returns nothing for the very task the PR exists to
rescue. The task is then either re-opened, spawning a duplicate Worker run against work already
recovered and awaiting merge, or left `done` while its work is provably not on `main`. Three tasks
sat `done` with open `op/recover-*` PRs, caught only by the operator noticing the PRs by hand.

A PR found under **any** head counts. The head name is a naming convention; the identifier in the
title or body is what ties a PR to a task.

## Why re-opening is mandatory once the pre-check fails

The audit exists for the "committed in a worktree, never pushed, never PR'd" case. The Architect's
next run pushes and opens the PR — that is why it has `gh` access. The operator's only manual git
role is merging and the occasional cherry-pick, which step 4 already accepts as a merge path.

The rationalizations that defeat this are all descriptions of the disease rather than reasons to
skip the cure: *"the work exists, why churn?"*, *"the operator will catch up"*, *"this is a known
bottleneck"*. Step 4 is the cure for false positives; there is no second one.

The one real risk is a re-open loop against a permanent Step 0 failure — hence the trailer and the
3-cycle escalation.

## What it does not catch

- Long-running batch verifies spanning multiple fires (the subtask correctly stays `in_review`;
  only flag once it goes `done`).
- Tasks where no SHA was ever recorded **and** the cherry-pick commit message does not mention the
  task id. Step 4 returns nothing, step 5 re-opens. Acceptable — re-opening is cheaper than
  missed-loss.
