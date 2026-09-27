# Why the self-audit measures the intake gate, not conversion

**Justifies:** Run step 6

Measuring only task conversion gave ~90% and read as healthy, while Coordinator's `ready >= 5`
gate meant a stretch of fires appended to a file Coordinator never opened. High conversion on
*old* items says nothing about whether *new* ones will be seen.

`ready` is `count(status == backlog)` literally, because Coordinator moves anything it cannot
dispatch to `blocked` with a `Held:` comment. Counting `in_review` and `todo` as well read a fully
drained pipeline as "5 in_review + 1 todo = at capacity" and skipped the restock a starvation
escalation had asked for. An `in_review` parent is usually a PR waiting on a human merge; `todo`
is dispatched queue, not supply.
