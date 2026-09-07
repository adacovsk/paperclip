# Why landing is decoupled from the verify run

**Justifies:** *Coordinator owns the LAND step, not the Architect.* (Landing sweep)

Landing has two parts with very different reliability. Compiling is long and may be starved;
pushing and opening a PR is short and nearly always succeeds. Putting both inside one run ties
the cheap, reliable part to the expensive, unreliable one.

The result is the worst available failure: cargo goes green, the run is then killed by a turn,
wall-clock or session budget before it pushes, and the verified work sits committed on a local
branch with nothing on origin to show for it. From outside, a task whose build succeeded and a
task that never ran look identical, so the work strands until someone drains it by hand — and
every point-fix that kept landing inside the run reproduced it.

Moving the step to a caller that fires on a routine breaks the coupling: it cannot be starved
mid-compile, because it is not compiling. The verify run keeps the part only it can do, and
the part that just needs to happen reliably moves to something reliable.

Making the sweep idempotent is what lets both hold the responsibility without coordination —
the verify run may still push, and the sweep is harmless if it already did.
