# Why teardown is gated on ancestry, and why a failing branch is parked

**Justifies:** *Teardown is gated on `merge-base --is-ancestor`, not on task status.* (§Worktree teardown)

## Why the gate is a hard stop and not a warning

Deleting a branch destroys the only remaining ref to its commits, and git will garbage-collect
them. There is no undo and nothing surfaces the loss.

Two complete, review-clean tasks were `cancelled` with no comment while holding unique commits — a
five-file data-and-Rust fix and a three-file docs fix, on no remote at the time. A later sweep
pushed them; a still later teardown deleted the remote branches again. When they were finally
looked for, all three commits existed **only as unreferenced loose objects in one checkout**, one
`gc` from unrecoverable.

## Why `git branch -d` is not this check

It compares against the **current HEAD**, not `origin/main`. So it refuses genuinely-merged
branches and permits unmerged ones — wrong in both directions, and confidently.

## Why status is not the check either

A `done`, `cancelled` or `blocked` status says what someone decided; it says nothing about whether
the work reached `origin/main`. Those are independent variables, and the ancestry gate reads the
one that matters. The §Landing sweep vocabulary note applies verbatim here: "landed" means merged,
never "a PR existed". This is the same argument §Branch disposition on close makes from the other
direction.

## Why a failing branch is parked rather than deleted

An accumulating unmerged branch is a **visible, cheap** problem. A deleted one is an **invisible,
permanent** one. So push it if it is not on origin, name it in the record with its commit list, and
leave it for the operator.

## Why the reap comes first

Removing the directory out from under a live cargo does not stop it. The build survives with its
cwd marked `(deleted)`, keeps holding one of only a few `cargo-sem.sh` slots, and burns CPU for a
task that is already merged. Observed on one task: a build chain held cargo-slot-2 against a
deleted worktree for ~67 minutes of rustc CPU before anything reaped it.

## Why ancestry alone is the wrong *only* test

A squash-merge replays the branch as one new commit, so the original tip is never an ancestor of
`main` even though every line of it landed. Ancestry is the right **first** test and the wrong
**only** one.

Measured in `$PAPERCLIP_REPO` while cleaning it: three branches whose PRs had all been merged each
failed `--is-ancestor` by one commit, purely from squashing. Verifying each PR's
`mergeCommit.oid` against `origin/main` settled all three in one call.

Left alone, the gate refuses every squash-merged branch forever, worktrees accumulate without
bound, and the rule gets disabled rather than obeyed — which is a worse outcome than the deletion
risk the gate exists to prevent. A gate that is always wrong stops being consulted.

The fallback uses bare `gh` from the project checkout, matching every other `gh` call in
INSTRUCTIONS; an earlier draft referenced an undefined `$GH_REPO`, which would have made the lookup
silently return nothing and the gate refuse exactly as before.
