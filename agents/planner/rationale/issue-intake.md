# Why the Planner owns GitHub issue intake

**Justifies:** Run step 5 — *GitHub issue intake (fill) — the operator's other insertion point*

Coordinator's only issue intake filters on `--label ci-failure`. An issue the operator files by
hand is therefore read by nobody: it is not a roadmap bullet, so Coordinator never promotes it,
and it carries no `ci-failure` label, so the one path that reads issues skips it. It sits open
forever. The step lives in the Planner, not Coordinator, because **the roadmap is the single
supply line** — a second promotion path in Coordinator would fork intake and split its own
capacity gates against themselves.

The label is load-bearing: an unmarked issue is re-read and re-decided every fire, the same
"re-skipped forever" failure as the skip-word rule, just with the operator's own requests.

## Worked example — the bootstrap case

*"Use paperclip harness to open local claude code instance with remote-control… I can no longer
access my remote terminals."* This is `ops`, not roadmap, and the reason generalises: it asks the
harness to repair the host the harness runs on. Every agent that could act on it is started by
the machine that is down, so the pipeline cannot execute it however well the bullet is phrased.
Routing it to the roadmap converts an actionable request into a bullet that fails silently.

## Why a pruned bullet closes its issue

Normally the PR carried `Closes #<n>` and GitHub closed the issue on merge. Step 7's close is the
fallback for a PR that left the keyword out: step 5 labels the issue `roadmapped` on intake, and
the completion criteria read that label as finished intake — so the mark that says "handled" also
guarantees the issue is never re-read, and it stays open forever. Two shipped guards sat open
that way with their bullets still in the index.
