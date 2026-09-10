# The express lane

**Justifies:** *Export `CARGO_SEM_PRIORITY=1` before the launch when — and only when — the task is marked priority.* (Cargo discipline rule 3)

Strict FIFO has one pathological case, and this is it.

A red main branch gates every verify in the queue: until it is fixed, the builds waiting behind
it are computing results against a base that cannot land. The fix for that condition draws a
ticket like any other work, so the one build that would release everything else queues behind
builds whose results are already worthless.

Fairness is what produces this. The queue is behaving correctly and the outcome is still the
worst available ordering, because FIFO cannot see that one item is a precondition for the rest.

The lane skips the queue but never the slot: a running build is left to finish, since
preempting one discards real work to save queue position.

**Scarcity is the safety property, not the label.** An express lane that anything may enter is
just a second queue, and a flood of express builds starves the normal lane by construction. It
works because almost nothing uses it — so what has to be bounded is the *number* of express
tickets, and restricting entry to one label was only ever a proxy for that.

The proxy was too tight in one direction. A red base is not the only precondition-for-the-rest
that FIFO cannot see: a contention fix — the branch that many in-flight worktrees will have to
rebase onto once it lands — is the same shape, and one measured instance drew a ticket behind
39 waiters, ten of which edited a file it would force a rebase on. Those slots were spent on
results a later merge invalidated. Nothing in the pipeline could say *this build unblocks the
others*, so the pipeline could not act on the one thing that would have helped.

Hence the second qualifier: a `Priority-verify:` line written by the Coordinator, with its
reason stated. It is deliberately not a flag the building agent may set for itself — the agent
holding a build has no view of what else is queued, which is precisely the judgement the lane
needs. And the bar stays "this unblocks other queued work", never "this task matters", because
the moment more than one or two carry it the lane has stopped working for anyone.
