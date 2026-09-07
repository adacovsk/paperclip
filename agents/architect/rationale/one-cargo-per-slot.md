# One cargo per slot, and the resume lane

**Justifies:** *One cargo per `cargo-sem.sh` call — never chain* (Cargo discipline rule 3)

A slot is held for the entire lifetime of the wrapped command. Wrapping a whole verify in one
invocation therefore holds a single slot across every stage of it — clippy, tests and all —
rather than across one compile.

This is why starvation persisted after the queue was made provably fair. Admission order was
never the problem; hold time was. A strictly fair queue still starves if the item at the front
holds its resource for hours, and no amount of ordering fixes that. Separate invocations each
take their turn and release in between, which is what lets the queue drain at all.

It is also why "one cargo at a time" and the staged gate are compatible with the semaphore
rather than in tension with it. The staging was always meant to be: run clippy, let go, run
tests.

**Why yielding is free, which is what makes the rule cheap to obey.** Releasing a slot between
stages used to send a half-finished verify to the back of the queue, so a completed clippy
result could sit unused while its tests waited through several full drains. That cost was the
real substance behind "verifies are slow", and it made chaining attractive for a reason that
had nothing to do with correctness. A resume lane — where the next cargo from the same worktree
outranks waiters that have not started — removes it, so there is no longer anything to buy by
chaining.
