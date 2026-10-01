# Why the decoupled-land step generates the PR body

**Justifies:** Run step 4 — *generate the body — never write it by hand*

This step used to tell the Coordinator to write the same four-section body the
Architect writes. It did fill in every heading, and put nothing under them. A
sweep that opens several PRs in one fire filled each one mechanically: a pasted
`git diff --stat` under What changed, the PR title again under Why, the commit
subject, or "Diff on task/... vs main", under Review focus. Across a run of about
thirty PRs from this step, nearly every one failed in at least one of those ways,
and every Architect-landed PR in the same window was fine.

The reasons were never missing. The task description quotes the roadmap bullet
the task was cut from, and the Worker and Reviewer commit bodies describe the
mechanism. Both were one command away. Copying them is a job a script does
reliably and a busy sweep does not, so the step now runs one instead of asking
for more care.

Review focus is the exception, because it takes judgement: naming the riskiest
hunk means reading the diff, and the sweep does not. So the generator writes
*not assessed* there. That is honest and still useful, because it tells the
reviewer to read every hunk. A pointer at the diff dressed up as an assessment
tells them nothing while looking like a review happened.

The generator runs the project's body check before printing, and the same check
runs in CI whenever a `task/*` PR is opened or edited. So a regression in either
the generator or a hand-written body goes red instead of reaching review.
