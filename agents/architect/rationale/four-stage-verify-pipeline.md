# Why the verify pipeline has four stages, shaped this way

**Justifies:** *One detached process, up to four slot acquisitions — the `&&` goes BETWEEN `cargo-sem.sh` calls, never inside one*, and the report-only fourth stage. (Cargo discipline rule 5)

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

## The fourth stage: report-only, and why that is deliberate

The gating stages compile the integration crates but never run them. A change confined to the
library can therefore break an integration suite at runtime and pass every gate.

Running them and reporting closes that blind spot. Making them *gate* would reopen a worse one:
integration suites are separately maintained and can be broken for reasons unrelated to any
task, so gating on them fails every task regardless of its own correctness — the exact failure
the library-only gate exists to prevent, where work bails before opening its PR and appears
finished with nothing to show. Whether integration failures should block is a policy decision,
not a tidy-up, so the result is captured before this stage runs and is never folded back in.

It runs *before* the sentinel is written because writing the sentinel fires the callback that
sends the run to land. A report produced after that point would arrive at a run that had
already finished, and would never reach anyone. Reporting costs the landing some wall-clock,
which is the price of the result existing at all.

Its status goes in a separate file so the two sentinels keep distinct meanings: one gates, the
other informs. A resource kill is recognised here the same way as elsewhere, since this stage
is heavy enough to be killed for memory and that presents identically to a real failure.
