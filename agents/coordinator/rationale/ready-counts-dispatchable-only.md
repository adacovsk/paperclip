# Why the capacity gate counts only dispatchable tasks

**Justifies:** *Count only tasks that are actually dispatchable, or this gate measures the wrong pool.* (Run step 9a)

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
