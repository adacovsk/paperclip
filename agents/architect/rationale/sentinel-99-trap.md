# Why sentinel 99 exists

**Justifies:** *the wrapper was signalled before cargo reported* (Procedure — sentinel state machine, `99`)

Before the trap, a killed wrapper wrote nothing at all. That left no sentinel and a dead pid,
which is exactly what a build still compiling looks like from outside — so a sweep could not
distinguish "we never found out" from "still working", and correctly declined to act on either.

The work then stranded indefinitely, and recovering it meant re-paying the full compile from
scratch.

`99` converts silence into a state. It says the run was interrupted before cargo reported,
which is neither a pass nor a failure, and it is actionable in a way silence is not: relaunch,
rather than debug code that was never compiled.

A SIGKILL still cannot be trapped — nothing can write a sentinel for it. That gap is closed
from the other side, by launching the chain in its own scope so the common killers reach it as
a signal it can catch.
