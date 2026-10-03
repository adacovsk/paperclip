# Why a red-main sentinel is archived rather than counted

**Justifies:** *A stale red sentinel is not a re-dispatch* (the Architect `in_review`, branch NOT
on origin row of the stage table)

## The failure

When `origin/main` is red, every cloud verify launched on it fails the same out-of-scope tests
and writes `{task-id}.exit` = `1`. The verdict says so: `fixes: 0` and every failure outside the
task's files. The ci-fix then lands and the tasks are re-dispatched. The Architect's state
machine reads **present, `1`** as a finished verdict and never reaches **absent + no build**,
which is the only branch that launches a build. So a re-dispatch after the fix builds nothing,
reads the same red, and counts toward the cap. Two re-dispatches later the task sits in
`Held: operator` with its branch unlanded. Nothing is wrong with the branch, and the failure it
is held for is already gone from `main`.

This hit 24 verifies in one day, across two red-main episodes (the lib ratchets, then the
settlements schema). Each one needed an operator to move files by hand. The Coordinator's own
hold comments diagnosed it correctly ("the only sentinel is stale") and still had no rule that
let it act.

## Why the three conditions

- **Every failure outside the task's files.** A failure in the task's own files is the task's.
  Rebuilding against a newer main does not change it, and it keeps counting. The VM may also fix
  errors outside those files when the task's own diff caused them, so a failure left outside them
  is usually main's. When it is a diff-caused one the VM ran out of rounds on, the next clause
  still holds the reset back: main has to touch that very file, and if it has, a rebuild is
  warranted anyway.
- **`origin/main` moved past the base.** If main has not moved, a rebuild reproduces the same
  result.
- **A commit since the base touches a path the verdict names.** Without this clause, a main that
  is still red would reset the sentinel on every unrelated merge, and each reset is a full cloud
  build against account quota. With it, the reset fires only when main has changed the thing that
  failed. That is a cheap, git-only proxy for "the fix landed".

## Why archive, not delete

The verdict is the only record of what the branch did on that base. Moving it keeps it readable
if the rebuild comes back red for a different reason.
