# Why "landed" is reserved for merged

**Justifies:** *"landed" means merged into `origin/main` — never merely "a PR exists"* (§Landing sweep; §Branch disposition on close)

Opening a PR is the Landing sweep's whole output. The merge is the operator's, and only the
operator's. A task whose commits are still only on `task/{identifier}` is not landed no matter how
green its cargo run was.

Marking such a parent `done` reports work as shipped while it sits on an unmerged branch — which
is exactly how a batch of tasks went `done` with conflicting, never-merged branches. `done` is
also the signal every other sweep reads: it unblocks dependents and the roadmap counts it as
shipped, so an early `done` hands downstream work a premise that is not yet true. One task was
recorded landed on an open PR and unblocked a dependent on the strength of a function existing on
`main`, where it did not yet exist.

The test is `git merge-base --is-ancestor <sha> origin/main`, never the existence of a PR.

Two corollaries that look like they belong elsewhere but are the same rule:

- **Trust `mergedAt`, not `state`.** A `CLOSED` PR is not merged, and `MERGED` as a state string is
  redundant with the field that carries the fact. Test the field, so a closed-unmerged PR can never
  read as landed.
- **Do not re-verify against the latest `main` on every fire.** That re-rebase + re-cargo loop is
  the livelock itself. Cargo-green against a *recent* base plus a clean textual merge is the
  accepted bar; merge-interaction regressions are caught later by a `ci-fix`, not by blocking the
  land.
