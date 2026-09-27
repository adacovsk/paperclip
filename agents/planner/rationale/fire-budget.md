# Why a fire runs its spine first

**Justifies:** *Fire budget — spine first, fill second*

A fire has a bounded wall clock and turn count, and this loop has outgrown both before: the
steps grew tenfold in four months against a budget that never moved. The failure was always the
same shape — the fire died *after* committing and *before* pushing, so the work existed nowhere
Coordinator could read it. A fire that runs its steps in written order until it dies loses
exactly the wrong half.

Step 6's queue check runs before step 4 because it is two API calls and its answer decides
whether the two most expensive fill steps are worth starting at all.

A local commit satisfies "an updated ROADMAP.md" literally, so a fire that commits and then dies
has, by its own contract, succeeded — while Coordinator reads `docs/ROADMAP.md` from `main`, sees
nothing, promotes zero and escalates a *supply* shortage that is really a *delivery* failure.
One commit sat unpushed a full day this way. Every peer agent has a push gate (Architect requires
a pushed branch, Reviewer requires `git log origin/main..HEAD` non-empty); the checkpoint in step 7
and the delivery gate in step 11 are the Planner's.

Naming the fill you skipped is what makes a bounded fire resumable rather than merely truncated.
Silently skipping it is what makes the loop look healthy while it quietly stops covering half
its steps.
