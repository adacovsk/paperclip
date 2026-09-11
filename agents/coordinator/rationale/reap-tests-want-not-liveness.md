# Why the reap test is "does the task still want a result", never process liveness

**Justifies:** *The test is whether the TASK STILL WANTS A RESULT — never process liveness.* (§Reaping an unwanted verify build)

## Liveness is not the question

A live wrapper whose dispatching run has died is **not** an orphan. That is the normal
decoupled-land pattern: the run hits its 2h watchdog while the detached build legitimately
continues — observed alive at 3h09m — and still writes its sentinel. Killing on pid-liveness alone
destroys live work.

So every admitted reason is admitted because the task *provably cannot consume the result*, not
because nothing appears to be running.

## Why `blocked` is not a reason

The obvious rule — "blocked on conflict, so a rebase is needed, so the build is invalid anyway" —
was measured **false**. Two `blocked` tasks holding live builds both merged **clean** into
`origin/main`, while a branch that genuinely conflicted belonged to an `in_review` task that
legitimately wanted its result.

A block is reversible without a rebase, and the freshness gate already allows landing on a slightly
stale base, so a blocked task's build is *deferred*, not worthless. `reap-verify.sh` therefore
re-proves `unlandable` with `git merge-tree --write-tree` on every invocation and **refuses** when
the branch merges clean, rather than trusting a status.

That leaves the real cost of a long-blocked build — it holds a slot or a FIFO position ahead of
work that can land today — as a **scheduling** problem, not a correctness one. It belongs to the
verify queue's priority ordering, and must not be solved by killing the build.

## Why the script writes the sentinel before signalling

`reap-verify.sh` writes `100` *before* it signals. The wrapper's own trap writes `99` only when the
sentinel is absent, and `99` means "inconclusive — relaunch" to the Architect. Reap without the
pre-write and the next wake restarts the build you just killed: the reap costs a build and frees
nothing.

## Why `ps aux | grep <worktree-path>` reports a false clean

Twice over. It matches on *cmdline*: `cargo-sem.sh` embeds the path, but its `cargo` /
`clippy-driver` / `rustc` descendants inherit the directory via `cd` and carry relative paths, so
they never match. And once the directory is gone the kernel marks the cwd `(deleted)`, so even a
cwd grep on the live path stops matching.

The script prefers the transient scope (`systemctl --user stop verifyrun-<id>.scope`) — an exact
atomic handle on the whole cgroup — falling back to the slot-lock + `/proc` probe with a
process-*group* kill for builds launched without a user bus.

## OFF-BOOKS builds

`reap-verify.sh --list` marks builds whose directory is not a `task/AA-*` worktree as **OFF-BOOKS**.
An operator worktree or the main checkout consumes the same slots but has no task, so no reason can
be proven about it and the script will not touch it.
