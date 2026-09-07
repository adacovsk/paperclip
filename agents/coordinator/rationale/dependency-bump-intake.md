# Why dependency bumps need their own intake

**Justifies:** *Do not drop this step without restoring that trigger* — the dependency-bump intake (Run step 2a)

A dependency bump arrives as a pull request, not as a task, so no agent has a reason to touch
it. Every other build in this pipeline is triggered by a task moving through a stage; a bump
moves through nothing.

CI used to cover that gap by building bump PRs on `pull_request`. That trigger was removed to
conserve Actions minutes, which left the bump verified by nobody — mergeable, green-looking,
and never compiled.

The failure mode is quiet and slow. A bump can remove or rename an item the code depends on
while the library's own tests keep passing, so the break surfaces only in whatever
configuration nothing routinely builds, and it sits on the main branch until someone happens to
compile that configuration.

The step and the removed trigger are two spellings of the same coverage. Dropping this without
restoring that leaves the gap open, so the two must be considered together.

The intake is scoped to manifest changes rather than to a bot account, so a hand-edited
dependency is covered on the same reasoning. Verification is also deliberately separated from
merging: the build reports a result, and whether to take the bump stays an operator decision.
