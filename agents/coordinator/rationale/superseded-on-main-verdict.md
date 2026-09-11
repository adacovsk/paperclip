# Why a written verdict, and not another probe

**Justifies:** *Superseded-on-main verdict* (§PR-evidence audit step 4e)

Every probe in the on-main pre-check is **attribution-scoped**: a PR on this branch, a SHA this
task names, a commit message naming this task. None can observe a done-when satisfied by **a
different task's PR** — and when that happens all of them correctly return nothing while the audit
concludes the opposite of the truth. The work landed, under someone else's attribution.

Re-opening then costs a wake per cycle and can dispatch a Worker at already-correct code. One task
flipped **five times** this way, and the one remaining action its done-when described was deleting
a run condition that `main` documents inline as *"Do not delete this condition"*. A second worked
example: `main` implements a task's subject through a different design, so its own three commits
can never become ancestors of `main` and every probe will keep returning nothing forever.

The marker is deliberately a *written verdict* rather than a sixth probe. Machine-deciding "is this
done-when satisfied?" against arbitrary code is exactly what the audit cannot do. Someone who has
read the code can state it, and the line makes that reading durable instead of something each fire
re-litigates.

The citation requirement is what keeps it from becoming a way to close anything: whoever leaves the
line **must** cite the implementing code — `path:line`, or the PR that landed it — so the claim is
checkable rather than asserted. **A marker with no citation is not a verdict; treat it as absent.**
