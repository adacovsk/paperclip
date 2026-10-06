# Why the verify pipeline has three stages, shaped this way

**Justifies:** *One detached process, up to three slot acquisitions — the `&&` goes BETWEEN `cargo-sem.sh` calls, never inside one*, and the absence of a `cargo test --tests` stage. (Cargo discipline rule 5)

## The third stage: the configuration nothing else checks

Feature-gated code is compiled by exactly one configuration, and if no per-change gate builds
that configuration, an error in it reaches the main branch. There it blocks every task, not
just the one that introduced it, and clears only by operator intervention.

Clippy rather than tests, because the failure class is a compile error. Clippy is check-level —
no codegen, no link — and the compiler cache is warm from the stage before it, so the marginal
cost is roughly one slot round-trip. A test build in the same configuration would be a full
relink of the heaviest, most memory-hungry stage, to catch nothing this stage does not.

The explicit `else` branch exists because a skipped stage must not look like a failed one.
Without it the group inherits the non-zero status of the test that decided to skip, and a
change with no relevant source reports a build failure.

## Why `tests/` is not run per task

The gating stages compile the integration crates but never run them, so a change confined to
the library can break an integration suite at runtime and pass every gate. That blind spot is
real; closing it per task is the wrong place.

Gating on the suites fails every task whenever `main` has a broken suite, regardless of the
task's own correctness — work bails before opening its PR and appears finished with nothing to
show. That is why a per-task run could only ever *report*. And a report-only run does not
belong in the verify either: it is the heaviest build in the chain after `test --lib`, so every
task paid for it out of the one build slot, while what it reported was almost always a failure
already on `main` that the task neither caused nor could fix. The same failure was reported on
every verify, to no owner.

The suites run nightly against `main` instead, under the Tester (`agents/tester/`). One run
states `main`'s health once, and each failure becomes a GitHub issue the Planner's intake
scopes into work, so it has an owner. What is given up is per-task attribution: a task that
breaks a suite lands, and the next nightly run names the merges since the last green run as
the candidates.
