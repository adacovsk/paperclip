# Why the capacity gate counts only dispatchable tasks

**Justifies:** *dispatchable only — skip unassigned tasks* (Run step 9a)

The gate asks one question — is there un-started work a Worker could pick up? — so it must
count only tasks a Worker will ever be handed.

Two large categories fail that test and accumulate silently. Unassigned tasks are invisible to
every wake path, so nothing can dispatch them however long they sit. Platform, pipeline and
host bugs belong to whoever maintains the machinery rather than to a Worker, and they are
routinely parked for weeks by design.

Counted, both inflate the queue depth without adding anything a Worker can do. The gate then
trips on that inflated number and skips intake, and the failure is invisible from either end:
the pipeline reports a deep backlog while the Worker sits idle, and the supply that would have
fixed it is never promoted. A depth measurement that includes undispatchable work does not
measure depth.

A third category joins them, and it is the one an assignee check misses. A task can be
assigned and still be undispatchable: parked on a question only the operator can answer,
missing the `worktree:` line its Worker hard-gates on, or held by step 5 because a file it
must edit is already in flight. Step 5 refuses to promote exactly these, which is correct —
but the same tasks then present to the capacity gate as supply, because they have an
assignee.

That is worse than an unassigned task sitting there, because it is self-reinforcing. Held
work suppresses the intake that would have produced work that is *not* held, so the queue
cannot refill itself out of the condition. The test is not "does this task have an
assignee" but "could step 5 hand this to a Worker on this fire" — if step 5 is holding it,
it is not depth, whoever it is assigned to.
