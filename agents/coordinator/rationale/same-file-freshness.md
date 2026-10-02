# Why the Landing sweep re-verifies when `main` touched the task's files

**Justifies:** §Landing sweep step 3b, the freshness gate.

## The failure

The Landing sweep opened a PR from a green sentinel and a clean `merge-tree`. Neither one says
anything about the code `main` gained since the build's base. One task's verify ran on a base
three days old. That task made `encumbrance_system` require a resource its tests never inserted,
and two encumbrance tests landed on `main` in the meantime. The PR merged and both tests panicked.
Textually the merge was clean. Semantically it was red, and the weekly CI run was the first thing
to find out.

The Architect's own Landing already has a freshness gate (re-verify when `origin/main` advanced,
capped at `$FRESHNESS_CAP`). The decoupled land bypasses that gate, because the Coordinator lands
from the sentinel without going back through the Architect.

## Why the same-file test

Re-verifying whenever `main` moves is the livelock §Landing sweep warns against: on a busy day
`main` moves every few minutes and nothing ever lands. A commit to one of the task's own files is
the narrow case where a clean merge most often hides a broken composition. It is new tests beside
the code, a changed signature, or a new required resource. It is also cheap to detect, with one
`git log` over the task's path list.

It does not catch a break across files, where the task changes a type and `main` adds a caller
somewhere else. Weekly CI, or a dispatched one, stays the backstop for that.

## Why it is bounded

Each re-dispatch counts toward `Verify re-dispatch: N`. A file hot enough to change on every cycle
exhausts the cap and goes to the operator, which is the right owner for a file that contended. It
is the same signal §Contention treats as a defect in the file.
