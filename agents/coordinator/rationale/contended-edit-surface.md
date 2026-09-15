# Why a contended edit surface is a scheduling decision

**Justifies:** *Hold on a contended edit surface.* (Run step 5)

Two tasks editing the same file do not finish sooner than the same two run in sequence. They
finish later, because both are rewriting the same region at once, and whichever lands second
has to reconcile against a version it never saw while it was being written.

The failure compounds when several branches share one surface. A single commit landing there
breaks all of them at once, and each break is reported independently. What was one scheduling
decision arrives as several separate conflicts, each of which resolves the same region in
isolation and can resolve it differently.

**Same-shaped work is the tell, and it is easy to miss** — the bullets read as independent
because each names a different entry. If two items differ only in *which* variant or record
they handle, they touch the same code by construction, and treating them as parallel work is
what creates the pile-up. Promote one, and promote the next when the first has opened its PR.

## Why an open PR is not a hold

The hold protects work that is still being *written*. A branch with an open PR is finished: its
diff is fixed, and the only thing left is a human merge. Holding a candidate behind it does not
avoid a conflict. The candidate still starts from `origin/main` whenever it is promoted, and
whichever branch lands second still meets the other's diff. All the hold changes is *when* the
candidate may start, and it ties that to the operator's merge cadence.

That coupling starved the pipeline. Every backlog task sat behind an open PR, Worker slots stood
empty, and each fire recorded "PRs awaiting merge, 0 promoted." Merge order is the operator's
choice, and the pipeline should not idle waiting for it. A conflict that does occur is handled
at the land step's clean-merge gate: a one-path conflict goes to a Worker rebase task, and only
wider ones reach the operator.
