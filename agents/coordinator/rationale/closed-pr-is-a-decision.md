# Why `--state all` is load-bearing

**Justifies:** *OPEN THE PR — but first check whether one was already closed* (§Landing sweep step 4)

`gh pr list` defaults to **open PRs only**, so a closed one returns an empty list —
indistinguishable from "no PR was ever opened". Those two states need opposite actions.

Observed: a task had its PR closed unmerged by the operator; the next sweep read the empty list as
"needs a PR", pushed and opened a second one; that was closed too. The operator was handed the
same rejected work twice.

The deeper asymmetry is that **a closed PR is a decision written outside Paperclip entirely**, by
a human on GitHub, and nothing imports it. Every other terminal signal in this sweep is a status
the sweep writes itself. Treating an unimported decision as absence is what turns "I rejected
this" into "please reject it again" — the pipeline's default is to re-derive rather than to
remember, and this is the one place that default is wrong.

Hence: a closed unmerged PR is terminal. Cancel the parent and the Verify subtask, name the PR and
its URL, and state the closure is being treated as terminal. If the work is still wanted it comes
back as a new task with a new premise — the operator's call, not a sweep's.
