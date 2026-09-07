# Why the detached-launch rule is inverted

**Justifies:** *Do not revert this to "block and poll"* — the detached launch (Cargo discipline rule 2)

This rule once said the opposite: background the build, then block by polling, and never end
the run mid-build. The sentinel machinery exists to replace that, and the two cannot coexist.

The reason is a mismatch in when the two clocks start. A run's watchdog begins at dispatch; a
build's work begins when it acquires a semaphore slot. Past the slot ceiling those are far
apart, so a blocking run spends its entire budget waiting in the ticket queue and is killed
having compiled nothing. Under contention this affects every waiter at once, since they are all
blocked on the same ceiling.

Blocking never makes a build finish sooner. It only guarantees that the waiting, rather than
the compiling, is what gets billed. A detached build outlives the run that launched it, which
is the whole point of the sentinel, pid file and callback.

**The old rule was right about its own failure, which is why half of it survives inline.** It
was written against runs that announced they were waiting and then exited without writing a
sentinel — losing the result, and leaving nothing to distinguish "still building" from "died",
so the task looped on no-op wakes. That failure is caused by an incorrect launch, not by
ending the run. Confirming the chain is genuinely running before exiting addresses it; blocking
addresses it only by accident, at the cost above.
