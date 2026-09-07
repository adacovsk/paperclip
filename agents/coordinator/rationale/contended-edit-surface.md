# Why a contended edit surface is a scheduling decision

**Justifies:** *Hold on a contended edit surface.* (Run step 5)

Two tasks editing the same file do not finish sooner than the same two run in sequence. They
finish later, because whichever lands second has to be merged by hand — so parallelism that
looks free is really borrowing the operator's time and paying it back with interest.

The failure compounds when several branches share one surface. A single commit landing there
breaks all of them at once, and each break is reported independently. What was one scheduling
decision arrives as several separate requests for a hand-merge, each of which resolves the same
region in isolation and can resolve it differently.

**Same-shaped work is the tell, and it is easy to miss** — the bullets read as independent
because each names a different entry. If two items differ only in *which* variant or record
they handle, they touch the same code by construction, and treating them as parallel work is
what creates the pile-up. Promote one, and promote the next when the first has merged.
