# Why sentinels are symlinked under the subtask id

**Justifies:** *the launch also symlinks them under the* `Verify:` subtask id (Cargo discipline rule 7)

Without the aliases, anyone probing liveness by the subtask id (Coordinator's re-dispatch check does exactly that, since that is the row it iterates) finds no `.pid` and no `.exit` even while cargo is actively compiling, concludes "never started", and re-dispatches — which killed a live build and threw away ~50 min of progress under semaphore contention.
