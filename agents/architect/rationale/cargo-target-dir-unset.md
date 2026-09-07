# Why the launch unsets CARGO_TARGET_DIR

**Justifies:** *`CARGO_TARGET_DIR` is unset explicitly* (Cargo discipline rule 10)

A daemon started before the `~/.profile` change still exports `CARGO_TARGET_DIR=~/.cargo-shared-target` — observed live, four days stale. That silently reverts the per-worktree `target/` design and forces every concurrent Architect to serialize on one `target/.cargo-lock`. `unset` makes the worktree isolation hold regardless of when the daemon last restarted.
