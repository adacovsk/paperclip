# Why the backlog fill follows the cloud lane

**Justifies:** *Fill to `target`, not past it, while the cloud lane is open* (Run step 8a)

Every `needs-build` task filed eventually competes for a cargo build. With the cloud lane
closed those builds are the local slots, so filing more than a few per fire only queues work
behind them; the cap of 3 protects the slots. With the lane open, verifies build on VMs and the
Architect is not the binding resource, so a cap only defers supply that the Coordinator's step 5
could already dispatch.

The ceiling is `target`, not the whole index, because a filed task freezes a roadmap bullet at
the moment it was filed. The Planner rewrites and prunes the index several times a day, so a
task filed far ahead of dispatch is promoted against a bullet that has since moved; the
Coordinator's re-validation then cancels or re-anchors it. Filing to the Worker's run slots
keeps every slot fed and nothing stale.
