# The ci-failure express lane

**Justifies:** *A `ci-failure` task exports `CARGO_SEM_PRIORITY=1` before the launch; nothing else does.* (Cargo discipline rule 3)

Strict FIFO has one pathological case and this is it: a red `main` gates every verify, but the ci-fix that would clear it draws a ticket like everything else and queues behind builds whose results are already known to be worthless.

Measured — the ci-fix sat 6th while all three slots were held by verifies whose own tasks had since moved to `blocked`, so the single build that would have unblocked ten tasks was the last to run.

The restriction to `ci-failure` tasks is the whole safety property: the lane works because almost nothing uses it.
