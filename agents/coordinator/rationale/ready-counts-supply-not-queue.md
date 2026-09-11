# Why `ready` counts `backlog` and nothing else

**Justifies:** *`ready = count(status == backlog)`* (Run step 9a)

Step 9a carries two questions that look like one:

1. **Is there un-started supply?** — what roadmap intake restocks. The population is `backlog`.
2. **Is there queue depth a Worker can pull from?** — what step 5 promotion restocks. The
   population is Worker-assignable `todo` + `in_progress`.

For most of this gate's life a single counter spanned both (`todo, in_progress, backlog`), which
answers neither. A backlog that grows because promotion is not running raises the counter, so
intake skips — and skipping intake does nothing to promote. The gate reports "queue is deep"
while the Worker is idle, and the deeper the backlog gets the more permanently intake is off.

Measured when this was traced: `backlog` 20 rows (13 promotable parents), `todo` 7 rows of which
**zero** were Worker-dispatchable — four unassigned `Verify:` rows already excluded by 9a's own
dispatchable rule, two assigned to Planner, one a Facilitator finding. `ready` read 13+, intake
skipped, and the Worker's `todo` queue was empty. Both statements were true at once because one
counter was being asked both questions.

Splitting them makes each gate act on the thing it can actually fix: deep `backlog` → skip intake
and promote; shallow `backlog` → intake. The failure mode to watch for is someone re-merging the
counters to make a starved Worker show up in the intake gate. It will not help: the Worker is
starved by step 5, and step 9 cannot feed it.

This counter has now been repaired four times (dispatchable-only, `inflight` scope,
two-gates-not-one, and this). That history is the argument for leaving the rationale attached to
it rather than trimming the note.
