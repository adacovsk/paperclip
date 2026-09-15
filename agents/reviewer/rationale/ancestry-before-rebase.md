# Test ancestry before rebasing, and tell "already merged" from "no work"

**Justifies:** *Sync to current main only if main is not already an ancestor.* (Step 0 checks 4 and 5)

## Why sync at all

A stale branch makes "this file changed" checks hallucinate: main moving forward looks like the Worker reverting things. What the review needs is "does this branch contain current main", which is an **ancestry** question, not a replay question.

## Why not rebase unconditionally

`git rebase` asks "do this branch's original commits replay cleanly onto main", which is permanently false once the operator has **hand-merged** the branch. Main then already contains these commits, so the replay finds nothing to apply or conflicts against itself. The branch stays blocked forever even though it can be merged without trouble. That failure burned two full agent fires and a Facilitator unblock/re-block cycle on one task before anyone diagnosed it. `--is-ancestor` returns true in exactly that case, so the rebase is skipped and review proceeds.

## Why an empty log has two answers

After a hand-merge, `git log origin/main..HEAD` is empty because the work is *on main*, not because the Worker did nothing. Reporting it as missing Worker commits reads as a Worker failure and sends the task back round the loop for work that already shipped. Fixing check 4 alone just moves the block to check 5, the same blind spot one step later.
