# Why the exit gate covers decisions, not just edits

**Justifies:** Run step 10 — *Exit gate — status matches conclusion*

Three tasks were found parked `in_review` for 16–24h whose newest comment opened *"`done` —
decision recorded"* and *"Closing `done`"*, with no `activeRun` and no `executionRunId`, so
nothing would ever re-wake them. The verdict had been written and the PATCH never made. An
`in_review` task with no live run is indistinguishable from a stalled stage: every Facilitator
sweep re-examines it, and the missed-wake heuristic toggles the assignee and re-dispatches the
Planner onto work it already finished, burning a run each time. A comment left on a task still in
`todo` is not completion either — a done-but-unPATCHed task looks like un-started work and
inflates the apparent queue.
