# Why liveness uses a census, not a per-id grep

**Justifies:** *The `+` is load-bearing* — the wrapper census (Cargo discipline rule 7)

The `+` is load-bearing. With `[0-9]*` the pattern matches zero digits against the literal `verifyrun-AA-[0-9]*` sitting in the pipeline's own argv, and the census grows a phantom bare `verifyrun-AA-` row — measured at 10 such rows on this box. Anchoring on one-or-more digits leaves the census clean. A build waiting on a busy `cargo-sem.sh` slot (both `/tmp/cargo-slot-{1,2}.lock` held) can sit 20–40 min showing only the startup `echo` — that is RUNNING, not dead.
