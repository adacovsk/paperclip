# Why a fire drains to the Worker's run slots, and wakes the Planner when the backlog runs short

**Justifies:** *Promote backlog → `todo` until the Worker's run slots are full* (Run step 5), *Backlog low → wake the Planner.* (Run step 9), and *Every wake refills free Worker slots* (Wake triage)

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

## Why the Planner keeps the backlog

Roadmap intake used to be this agent's step 9, with the Planner restocking the roadmap behind
it. That split gave the backlog two owners and each read the other's state as the reason to
wait. The Planner counted about 200 free fronts and skipped its restock, because supply was not
the constraint. The Coordinator found the backlog empty and an open restock request on the
Planner, and recorded intake as "not run, the Planner holds the restock". Backlog, `todo` and
`in_progress` all sat at zero with twelve Worker slots free, while every fire of both agents
succeeded.

Intake is also the most expensive part of a full sweep — an overlap search and a contention
test per front — and the sweep is debounced, so it ran at most twice an hour and was the step a
fire short on budget cut first. The Planner already reads the whole index every fire and owns
the rules that decide what is promotable, so it files the backlog directly. This agent keeps
dispatch, where the slot count and the worktrees live.

## Why a short backlog wakes the Planner, and on every wake

The request is created on a debounced wake as well as a full sweep, because Worker stages end
in minutes and a short backlog found only by the half-hourly fire idles the freed slots for the
half hour. Creating it is two reads and one write, and the open-request dedupe makes repeating it
free.

Re-dispatching an idle open request is different: on every callback wake it would fire the
Planner, the most expensive agent in the fleet, every few minutes. So only the full sweep
re-dispatches it.

## Why an open request is re-dispatched, not just skipped

Skipping while a request is open assumed the request would close. The Planner keeps it open
until the backlog reaches target, and a bounded fire routinely ends short of that. If skipping
were the only rule, the one waker would wait on the one thing that cannot happen without it: an
earlier form of these two rules left the pipeline with zero dispatchable backlog for eight hours
while every Coordinator fire succeeded in about a minute.

Re-dispatching the same task keeps the one-request dedupe and closes the loop. The live-run
check stops a second fire landing on one already in flight, and the full-sweep cadence bounds
the rest.
