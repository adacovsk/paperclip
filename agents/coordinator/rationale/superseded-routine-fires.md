# Why an older routine fire is dead by definition

**Justifies:** *Close superseded routine fires.* (Run step 0a)

A routine task is checked out by the fire that claims it, and nothing closes it afterwards if
that fire never runs. Waiting behind a deep callback queue, a fire can exhaust its budget
before reaching any work, leaving the task it checked out parked with no comments, no active
run and no execution lock.

That state is indistinguishable from a fire still working — which is why it accumulates rather
than being cleaned up.

The current fire resolves the ambiguity by existing. Only one fire of a given routine is live
at a time, so any older one still open has already been superseded and can be closed on that
reasoning alone, without probing it.

Status is the load-bearing part of that close. A comment is optional and not always free: on a
deep queue each one costs another wake into the queue being drained.
