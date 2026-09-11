# Why verifies are capped, and why the only hold is a NULL assignee

**Justifies:** *Cap concurrent verifies at 2x the semaphore's ceiling* and *Holding the surplus
means leaving `assigneeAgentId` NULL* (§Architect dispatch)

## Why a cap at all, when the semaphore already bounds concurrency

`cargo-sem.sh` bounds what *runs*. Nothing bounded what was *handed to it*. Left unbounded, live
wrappers accumulate to an order of magnitude more than there are slots, and the queue head can
wait most of a day for a few minutes of CPU. Each verify takes up to four slot acquisitions
(clippy, `test --lib`, `clippy --no-default-features`, `test --tests`), so 30 verifies is ~120
acquisitions — a multi-day drain.

Throughput does not merely plateau past the cap, it **degrades**: cold dependency rebuilds contend
for sccache, whose Rust hit rate was measured decaying under exactly this load. Meanwhile the
pipeline reports healthy on every cheap probe — moving log mtimes, busy slots, live scopes — which
is why it ran so long unnoticed.

## Why the hold has to be a NULL assignee

Setting `assigneeAgentId` = Architect fires an on-demand wake within seconds **regardless of
status**. Assigning the Architect *is* the dispatch; `in_review` is not a parking status, it is
where a dispatched verify lives.

One fire PATCHed two bumps to `in_review` + Architect with a comment saying they were being held.
Both launched inside 60 seconds, taking the live census from 18 to 20 **in the act of enforcing a
cap of 4**. Every earlier fire that believed it was holding surplus this way was in fact
dispatching it — the best available explanation for how the queue reached 30 while the cap was
written down and obeyed.

## Why "dispatch all their Architects in the same fire" is not coming back

That line lived in §Architect dispatch and is what licensed the 30. Dispatching everything was
safe only under the old **blocking**-Architect model, where a queued run cost nothing. With
detached builds each dispatch is a live wrapper holding a worktree lock and a ticket.

The inverse failure is also on record, so do not over-correct into a global lock: the run's hard
watchdog starts at **dispatch**, not at slot acquisition. If an Architect ever blocks on its build
instead of detaching, "waits its turn" and "burns its whole budget waiting, then dies on the
watchdog" are the same state — five verifies dispatched within 8 seconds, all five killed with
`Process lost`, nothing compiled. Dispatching concurrently is correct *given* detached builds; it
is not a licence to ignore the ceiling when Architect runs die without build output.

## The semaphore, and the shared-target-dir history

Each Architect builds in its own per-worktree `target/`, so there is **no shared cargo build
lock**. Concurrency is bounded by the FIFO N-slot semaphore (`agents/architect/cargo-sem.sh`,
which superseded a raw-flock pair and, before that, a machine-wide mutex) wrapping the whole
clippy+test chain.

Its ceiling `CARGO_SEM_SLOTS` defaults to the **lower** of physical cores − 1 and a declared
memory budget, `(MemTotal x 70%) / 8 GiB per build`. On this 4-core / 31 GB box that is
`min(3, 2)` = **2**, not 3 — memory binds first, and the instructions said 3 for long enough to
matter. This is why the rule says read `/tmp/cargo-sem.slots` rather than re-derive it. Each build
is separately job-capped (`CARGO_BUILD_JOBS`, default logical/slots, floor 2) so N builds × their
job cap stays under the real core count. Slots are not core-pinned; the old 2-slot design's
`taskset` partitioning was dropped. A queued Architect past the ceiling waits its turn on a strict
ticket queue — no overtakes, self-healing on a dead holder/waiter — rather than thrashing.

Do **not** crank `CARGO_SEM_SLOTS`: on this thermally-throttling ULV chip more whole-machine slots
is measured-slower, not faster (see the tuning header in `cargo-sem.sh`).

**Background — do not re-introduce a shared `CARGO_TARGET_DIR`.** All Architects once shared one,
so cargo's single build lock serialized them. Under heavy queue depth the tail runs blocked past
their wall-clock budget, got killed mid-write, and corrupted the shared target — a multi-day death
spiral. The fix was unsetting the stale `CARGO_TARGET_DIR` from the systemd `--user` environment.

## Why an untracked build is reported and not reaped

A build launched outside a verify wrapper — an agent shell, an operator's hand-run — draws a
`cargo-sem.sh` ticket like any other but belongs to no task. Nothing will read its result, it
cannot commit or open a PR, and because it is normal-priority `express_waiting()` never yields to
it. It is pure contention against builds that can land. One measured instance sat **47 minutes**
producing a zero-byte log, racing the express build for the very regeneration that would have
unblocked the queue.

It is **deliberately out of the orphan reaper's scope**: `reap_escaped_orphans()` in `cargo-sem.sh`
requires cwd under `.paperclip/worktrees/`, so a build in `$PAPERCLIP_PROJECT` itself is never
killed. That exclusion is correct — the main checkout is where the operator builds by hand, and
killing their build to reclaim a slot is a worse failure than the slot.

Correctly-excluded is not the same as covered, though, which is why the gap is Coordinator's to
*report*. And the report stops there: a sweep cannot tell a deliberate hand-build from abandoned
debris, and guessing wrong destroys work whose only record is that process.

---

The detached-build contract referenced above lives in `agents/architect/INSTRUCTIONS.md` §Cargo
discipline rule 2: the Architect launches a `setsid` chain that writes an exit sentinel and fires a
wakeup callback, then ends its run.
