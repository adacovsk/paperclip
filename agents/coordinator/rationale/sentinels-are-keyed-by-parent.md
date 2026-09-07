# Why sweep artifacts are keyed by the parent id

**Justifies:** *Absence of a subtask-keyed sentinel is evidence of nothing* — the parent-id keying rule (Landing sweep)

Worktrees are allocated per parent task, and the verify runs inside one. So everything it
writes — sentinel files, branch name, process tag — is named after the parent.

The row a sweep iterates is the verify subtask, which carries a different id. Probing under
that id finds nothing even while a build is actively compiling, and nothing is exactly what a
build that never started looks like.

Read as "never started", the response is to dispatch again — and the re-dispatch lands on a
worktree that already has a build running in it, discarding everything compiled so far. Under
a contended semaphore that is the expensive form of the mistake, because the replacement has
to queue from the back.

The general rule is the one to carry: absence of a subtask-keyed artifact is evidence of
nothing at all. Resolve the parent id first, and the probe describes reality.
