# Why the reap is authorised by the gate, not by the status

**Justifies:** *Reap because THIS GATE JUST PROVED the branch cannot merge* (§Landing sweep step 3)

Blocking a subtask does not stop the detached cargo the Architect already launched. It keeps its
`cargo-sem.sh` slot until it finishes on its own, and everything landable queues behind it. The
worst shape is a red `main`: the ci-fix that would release the queue waits on builds whose results
nobody can use.

But the authority to reap comes from the **merge proof**, not from the new status, and the
distinction is not pedantry: `blocked` does not imply unlandable. A blocked task's branch usually
still merges cleanly, because the block is rarely a conflict; meanwhile a branch that genuinely
conflicts often belongs to a task that still wants its result. Status and mergeability are
independent variables.

`reap-verify.sh` re-runs `merge-tree` itself and refuses when the branch merges, so passing
`unlandable` from anywhere that has not proven it is rejected rather than obeyed. That check is
the backstop; this rule is what keeps callers from leaning on it.
