# The ci-failure express lane

**Justifies:** *A `ci-failure` task exports `CARGO_SEM_PRIORITY=1` before the launch; nothing else does.* (Cargo discipline rule 3)

Strict FIFO has one pathological case, and this is it.

A red main branch gates every verify in the queue: until it is fixed, the builds waiting behind
it are computing results against a base that cannot land. The fix for that condition draws a
ticket like any other work, so the one build that would release everything else queues behind
builds whose results are already worthless.

Fairness is what produces this. The queue is behaving correctly and the outcome is still the
worst available ordering, because FIFO cannot see that one item is a precondition for the rest.

The lane skips the queue but never the slot: a running build is left to finish, since
preempting one discards real work to save queue position. And it is restricted to a single
label because that restriction *is* the safety property — an express lane that anything may
enter is just a second queue, and a flood of express builds starves the normal lane by
construction. It works because almost nothing uses it.
