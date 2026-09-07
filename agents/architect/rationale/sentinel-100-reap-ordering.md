# Why the reap sentinel is written before the kill

**Justifies:** *the build was deliberately reaped; the task could not consume the result* (Procedure — sentinel state machine, `100`)

The wrapper's own signal trap writes its sentinel only when none is present. Writing the reap
code first therefore makes that trap a no-op, and the deliberate value survives the signal.

Reversing the order defeats the reap entirely. The trap wins the race and records an
interruption, an interruption means relaunch, and the next wake starts the very build that was
just stopped — so the reap costs a full compile and frees nothing. The remap for
resource-driven kills has the same shape and the same outcome.

This is what makes a reap distinguishable from every other way a build can stop. The other
codes describe things that happened to a build; this one records a decision someone made about
whether its result was still wanted. A slot freed on purpose should not be re-taken without a
reason, and only a code that survives the kill can say so.
