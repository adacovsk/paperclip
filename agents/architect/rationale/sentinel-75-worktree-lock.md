# Why the worktree-lock wait is bounded, and why its timeout is not a strike

**Justifies:** *the worktree lock never freed, so cargo never ran* (Procedure — sentinel state machine, `75`)

`cargo-sem.sh` serializes builds per worktree with an `flock`, taken before a slot is drawn so
a second build of the same directory waits without occupying capacity. An `flock` belongs to
the open file description, not to a process: it lives as long as *any* fd on that file stays
open, anywhere. So the lock does not end when the build ends. It ends when the last process
holding the file closes it, and a helper that outlives its build keeps it held indefinitely.
The pid `/proc/locks` records is only the process that *took* the lock, usually a subshell that
has already exited, so a dead pid there says nothing either way. A healthy build's lock shows a
dead pid too.

An unbounded wait on such a lock is the worst kind of failure, because it is invisible. The
waiting chain stays alive, so the liveness probe reads "build running" and nothing relaunches
it. The verify task sits in review forever with a missing `.exit`, and its subtask alias points
at a file that will never be written. Twenty-nine verifies were found stranded this way at
once, most having already passed clippy and the lib tests and stuck only at their last stage.

Bounding the wait turns that into a visible, recoverable outcome. The bound is well past any
legitimate same-worktree build, so reaching it is evidence of a leak, not of slowness. The
wrapper exits without running cargo, which is why it is not a build failure and must not enter
the fix loop. It is also not the `99` signal sentinel: nothing was killed, and counting it
toward the two-`99` escalation would escalate a lock leak as if it were a flaky build.

The cloud lane is the preferred relaunch because a VM has no access to this machine's worktree
locks, so the holder that blocked the local build cannot block it. Before exiting, the wrapper
names every process holding the lock file. Those lines are the only evidence of what leaked
it, which is why a repeat on the local path escalates *with* them rather than silently retrying.

One leak path is closed at the source: the cancellation watcher and every `sleep` it forks run
with the lock fds closed, as cargo already does. The bound is the backstop for any path
not yet found.
