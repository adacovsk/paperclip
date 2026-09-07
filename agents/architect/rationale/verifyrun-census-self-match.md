# Why liveness uses a census, not a per-id grep

**Justifies:** *The `+` is load-bearing* — the wrapper census (Cargo discipline rule 7)

A process listing filtered for a specific build's tag matches the filtering command itself,
because that command's own arguments contain the tag. So the probe reports the build alive
whether or not it exists, and it is the probe's own presence being observed.

Running one census over all ids and reading the result avoids self-matching, but only if the
pattern cannot match its own text. A pattern allowing zero digits does match the literal
pattern sitting in the pipeline's arguments, and the census fills with phantom entries that
belong to no build. Requiring at least one digit is what makes the census describe reality.

The second trap is reading elapsed silence as death. A build waiting on a busy semaphore
produces no output for a long time by design — it has not started compiling yet. Quiet is what
waiting looks like, not what dying looks like.
