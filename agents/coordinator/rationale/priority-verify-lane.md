# Why the express lane exists, and why crowding it destroys it

**Justifies:** *Marking a verify priority (`Priority-verify:`)* (§Architect dispatch)

`cargo-sem.sh` admits builds through a strict FIFO ticket queue with no overtakes, so build order
is pure arrival order. Nothing in it can express *this build unblocks the others*, which means the
most-unblocking build is scheduled by accident — usually last.

Measured: one contention fix — the file edited by 9 of 52 in-flight worktrees, and the reason zero
Worker tasks had been promoted for three consecutive fires — drew a ticket at the back of a
**39-deep** queue, behind 10 builds it would force a rebase on the moment it landed.

The lane skips the *queue*, not the *slot*: it never preempts a running build.

The bar is **"this unblocks other queued work"**, never "this task matters". A lane that everything
is in is FIFO again, so the lane's value is entirely in its scarcity — one or two in a queue, at
most. If you are about to write a third `Priority-verify:`, the queue has a scheduling problem the
lane cannot fix, and the useful action is to say that in your record.
