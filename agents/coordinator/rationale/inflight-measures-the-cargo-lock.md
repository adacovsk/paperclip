# Why inflight is not everything in_review

**Justifies:** *Not "everything `in_review`"* — the `inflight` definition (Run step 9a)

This gate exists to protect one scarce resource — the build lock — so it has to count that
resource and nothing else.

`in_review` is a much wider state than "queued for a build". A parent whose PR is already open
is waiting on a human to merge it, and consumes no build capacity at all. Counting it throttles
intake on a resource that is sitting idle, which is the exact inversion of the gate's purpose:
supply is withheld precisely when there is capacity to absorb it.

The measurable form is narrow and unambiguous — an open verify subtask, or a build slot held
against the worktree. Anything else is a different kind of waiting.
