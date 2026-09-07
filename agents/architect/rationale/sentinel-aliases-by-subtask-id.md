# Why sentinels are symlinked under the subtask id

**Justifies:** *the launch also symlinks them under the* `Verify:` subtask id (Cargo discipline rule 7)

Sentinels are named after the worktree, which belongs to the parent task. But the row a sweep
iterates is the verify subtask, so it probes under the subtask's id — and finds nothing, even
while the build is actively compiling.

Absence then reads as "never started", and the response to a stage that never started is to
dispatch it again. The re-dispatch lands on a worktree that already has a build in it, and the
progress made so far is lost.

Two ids naming one build is the underlying problem, and it cannot be fixed by choosing the
right one: each side is correct to use the id it holds. Aliasing every sentinel under both
makes either probe work, which is cheaper and more robust than requiring every reader to know
which id the file was named for.
