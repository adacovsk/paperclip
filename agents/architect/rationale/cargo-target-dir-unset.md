# Why the launch unsets the shared target directory

**Justifies:** *`CARGO_TARGET_DIR` is unset explicitly* (Cargo discipline rule 10)

A daemon carries the environment it started with, so a variable removed from the profile
survives in every process the daemon spawns until it restarts. Whether it is set is therefore a
function of when the daemon last came up, not of what the configuration currently says.

The one that matters here points every build at a single shared target directory. That silently
reverts per-worktree isolation: concurrent builds stop being independent and serialize on one
lock, which is the exact contention the worktree layout exists to remove.

Nothing about it is visible from inside a build — the compile is simply slower, and the cause
is an inherited variable rather than anything in the task. Unsetting it at launch makes the
isolation hold on its own terms, rather than depending on daemon uptime.
