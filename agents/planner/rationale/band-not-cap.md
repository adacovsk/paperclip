# Why step 8 restocks to a band, and why `needs-build` absorbs it

**Justifies:** Run step 8

## Why a band and not a per-run cap

Step 8 once read "≤3 new items/run". A cap bounds *supply* while demand is set by how fast the
pipeline consumes, so whenever consumption exceeds the cap the only way to keep up is to fire
the Planner more often — which is what happened. Consumption ran several times the per-fire cap;
the queue drained, the demand signal repeated within hours, and each repeat woke another fire
that minted another branch and another set of tasks. The Planner is the most expensive agent in
the fleet (~54% of pipeline spend), so a cap that forces extra fires is costly in the most direct
way. Restock to a depth and the wake rate falls out of it.

The band is a target across fires rather than a debt owed by one, because restocking is
demand-driven: an unmet floor is the signal that wakes the next fire. Treating "restock to 20" as
"keep authoring until the budget runs out" turns a fill step into a fire-ending one.

## Why the floor is promotable fronts, not the guard's free count

The guard's `(N free)` counts bullets with no `claimed`/`gated` marker and cannot see Paperclip.
Coordinator additionally skips anything overlapping a task active or closed in the last 7 days; a
multi-slice front whose last slice just landed carries no marker, so the guard counts it free
while Coordinator skips it. Judging the floor on the guard's number deadlocked the two agents:
the index read 38 deep with 30 free, the Planner skipped scan and restock as above-floor,
Coordinator promoted zero and escalated again, and nothing moved.

## Why one floor, and why `needs-build` runs dry last

A deep `data-only` target and a shallow `needs-build` one were each defensible alone; together
they meant the pipeline stocked whatever was cheapest to finish. `data-only` skips the Architect
and lands in minutes, so it always looks like the efficient band to fill — and sustained, that
yields a pipeline that mostly inspects itself: the roadmap fills with tooling about the tooling
while the mechanics backlog (battle forms granting nothing, riders with no crit gate, resistance
keys with no reader) stays a handful of items deep. Throughput is not the goal; shipped mechanics
are. Bundling (Output quality) is the sanctioned response to a saturated verify queue, because it
cuts builds without changing *what* gets stocked.

## Why sections are written small

A new section seeds its own ceiling in the section baseline, so whatever the first fire writes is
what the ratchet holds it to. That first write is the one place the roadmap's size is still a
free variable, and it is how the file reached 8,951 lines in a fortnight. `##` sub-headings had
hidden 1,611 lines across 71 headings from the ratchet and orphan sweep, making sections of 200
lines measure as 12.
