# Why a dispatch without a worktree is a livelock, not a wasted run

**Justifies:** *A task that keeps its `backlog` status must never carry a Worker assignee.* (Run step 5)

Every downstream agent hard-gates at its Step 0 on an allocated worktree (per-task-worktrees.md
§6). A Worker woken against a task with no `worktree:` path cannot do anything except abort, and
it aborts *cleanly* — the run succeeds, costs ~$0.42, changes nothing, and leaves the task exactly
as it found it.

That last clause is what makes this a livelock rather than a one-off waste. The task is still
`backlog`, still un-allocated, still assigned — so it is still a dispatch candidate, and the next
sweep fires the identical run. Four of these were measured in the last 50 company heartbeat-runs
of one fire (~$1.70), and one run's own result text records that it was the second identical
dispatch of that task.

Nothing in the loop degrades, so nothing escalates. The failure is invisible in every metric that
counts failed runs, because none of the runs failed.

The fix has to be at the *assignment*, not at the Worker. The Worker's gate is correct and must
stay — it is what stops a Worker editing the shared checkout. Retrying, backing off, or giving the
Worker a fallback allocation all move the allocation decision to the agent least able to make it;
Coordinator is the single writer on the worktree namespace, and allocation is its job. So the
precondition belongs on the write that fires the wake.

Distinct from the Worker *rebase* no-op and from completed stages being re-woken: both of
those dispatch onto tasks that do have worktrees.
