# Why dependent slices ship as one chain, not as numbered sections

**Justifies:** Output quality — *Chain dependent slices — one branch, one verify*

Sizing a section to one Worker run is right, and it stays the rule for each
step. What it got wrong for dependent work is the unit of *verification*.
Every `needs-build` section is a full Architect build and a place in the
verify queue, and dependent sections can only promote one after another. A
three-slice feature therefore paid three builds and three queue waits back to
back. With the verify queue several dozen deep, a waiting slice parked its
dependents for days: one feature's first slice sat in verify for a week while
its two later slices could not promote at all.

Bundling did not help, because a bundle needs independent members and these
slices are not.

A chain keeps the one-run-per-slice sizing and moves only the verification
boundary. The Worker does one step per run on a single branch, so no run is
larger than a standalone section and the turn-cap risk the bundle ceiling
guards against does not grow. The Reviewer and Architect then run once over
the finished branch. Per-step commits, tagged `Chain-step: <k>`, keep a red
build attributable to a step.

What a chain gives up is holding the branch through N Worker runs, which
widens its contention window. That is why every step's files must be
uncontended, both when the chain is written and when it is promoted.
