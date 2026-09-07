# Why the detached-launch rule is inverted

**Justifies:** *Detached launch — launch the build with its sentinel, then END your run. Do not block-and-poll.* (Cargo discipline rule 2)

This rule previously said the opposite: *background it, then BLOCK by polling, never end your run mid-build*. That is what the sentinel machinery was built to replace, and leaving it in place cost real work.

`cargo-sem.sh` admits only `SLOTS` builds at once (default = physical cores − 1), and a run's hard watchdog starts when the run is **dispatched**, not when it acquires a slot. So a blocking Architect past the slot ceiling spent its entire budget sitting in the ticket queue and was killed by the watchdog with `Process lost` — having compiled nothing. Observed: five verifies unblocked within 8 seconds, all five killed, load ~14 on a 4-core box.

Blocking did not make the build finish sooner; it only guaranteed the *waiting* was what got billed. A detached build survives the death of the run that launched it — that is the entire point of the sentinel + pid-file + callback design.

**The old rule was not wrong about its own incident, which is why the confirmation half of it survives inline.** It was written against a real class of loss: runs that emitted *"monitors armed, waiting…"* and exited **without** a sentinel, losing the result and looping on ~30s no-op wakes. The fix for that is a *correct launch*, not a blocking one.
