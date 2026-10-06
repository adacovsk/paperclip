# Why the verify pipeline has two stages, shaped this way

**Justifies:** *One detached process, two slot acquisitions — the `&&` goes BETWEEN `cargo-sem.sh` calls, never inside one*, and the absence of a `--no-default-features` stage and a `cargo test --tests` stage. (Cargo discipline rule 5)

## Why the `--no-default-features` configuration is not checked per task

Feature-gated code is compiled by exactly one configuration. While a per-task stage clippied
`--no-default-features`, a break there that reached the main branch failed that stage for every
later task, so it blocked the whole pipeline and had to be caught per task.

That reasoning only holds while verifies build the configuration. The two configurations differ
at six `hot_reload`/`dev` sites, and the Tester's nightly run clippies both against the main
branch. With no verify building `--no-default-features`, a break there blocks no task: it becomes
one issue the next morning. Checking it per task cost a third slot acquisition on every verify
that touched `src/` to prevent a failure that no longer stops anyone.

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
