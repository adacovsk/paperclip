# Why a fire drains to the Worker's run slots, and wakes the Planner when it runs dry

**Justifies:** *Promote backlog → `todo` until the Worker's run slots are full*, *No per-fire cap while the cloud lane is open* and *Drained → wake the Planner, once.* (Run steps 5, 9d, 9j), and *Every wake refills free Worker slots* (Wake triage)

## Why the ceiling is the Worker's own run slots

Step 5 promoted only while fewer than 2 Worker tasks were active. The Worker's
`maxConcurrentRuns` was 4, so half its capacity sat idle every fire while backlog held a dozen
dispatchable tasks. The Coordinator fires every two hours, so a fixed low promotion ceiling is a
throughput ceiling for the whole pipeline.

The number that actually bounds Worker parallelism is the agent's `maxConcurrentRuns`: the server
starts at most that many runs and queues the rest with no timeout. Promoting to exactly that
ceiling fills every slot without parking worktrees behind queued wakes. It is read from the agent
on every fire rather than written into these instructions, because a literal drifts silently the
moment someone retunes the agent — the instructions keep obeying the old value.

The contended-edit-surface hold still applies inside the ceiling. It exists to prevent merge
conflicts, not to limit load, so draining harder does not relax it.

## Why slot refill is not debounced

The debounce exists because a full sweep re-derives the whole pipeline, and most wakes change
nothing that sweep would find. Filling Worker slots is a different cost: a promotion is a
worktree and two PATCHes, and the alternative is Worker capacity sitting idle. A Worker stage
finishes in minutes, so a slot freed just after a sweep stayed empty until the next scheduled
fire — up to 30 minutes per slot, four slots at a time, while the cloud lane had quota to spare
and the Architect was running a dozen verifies. That made the Coordinator's timer, not the
Architect, the pipeline's binding constraint.

Only step 5 runs on these wakes. Intake, landing, audits and the routine record keep their
debounce, because those are the expensive re-derivations it was written for. The
contended-edit-surface hold is unchanged: refilling faster must not become merging-in-parallel
on one file.

## Why intake follows the lane

The cap of 3 new roadmap promotions per fire protected the local cargo slots: every `needs-build`
item taken in eventually competes for them. While the cloud lane is open, verifies build on VMs
and the Architect is not the binding resource, so the cap only defers supply that step 5 could
already dispatch. Backlog is supply; step 5 bounds dispatch. With the lane closed the local
constraint is back, and so is the cap.

The same reasoning removes the `inflight` row of the capacity gate while the lane is open — see
the verify-dispatch-cap rationale.

## Why one drained fire wakes the Planner

The escalation used to wait for two consecutive wraps with zero promotions. That was a guard
against a capped scan: a fire that took in 3 items and stopped mid-index could not tell "nothing
left" from "not reached yet", so it needed a second pass. An uncapped fire scans the whole index,
so one fire that scanned all of it, dispatched what it found, and still has zero dispatchable
backlog has measured the drain directly. Waiting another two hours for a second wrap just idles
the Worker.

The Planner restocks to a band rather than a per-fire quota, runs one fire at a time, and is the
most expensive agent in the fleet. A second restock request while one is open only queues a
duplicate fire, so the escalation is skipped while any `Roadmap intake starved` task for the
Planner is still open. The title prefix is kept so that dedupe also recognises requests filed
under the older wording.

## Why an open request is re-dispatched, not just skipped

Skipping while a request is open assumed the request would close. The Planner is told to keep it
open until it has rewritten or added promotable fronts, and a bounded fire routinely ends short of
that — prune pushed, next-slice rewrites not reached. Its instructions call the unmet floor "a
signal the next fire is woken by", but the only waker was this escalation, and this escalation
skipped because the request was open. The two rules deadlocked: the Planner ran once on a request,
pruned, left it `todo`, and the pipeline sat with zero dispatchable backlog for eight hours while
every Coordinator fire succeeded in about a minute. Nothing in the fleet read as failing.

Re-dispatching the same task keeps the one-request dedupe and closes the loop. The live-run check
is the only brake: it stops a second fire landing on one already in flight. There is deliberately
no idle cooldown on top of it. A drained backlog is the pipeline stopped, so throttling the restock
to protect per-run cost buys idle Worker slots at a far worse price, and a Planner with nothing
writable left says so in a run measured in seconds.
