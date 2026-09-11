# Reading a Worker's terminal state

**Justifies:** *A Worker never pushes, so the server's Layer-2 gate lands a finished Worker stage* (Run step 3)

A Worker never pushes by design, and the server's Layer-2 gate holds an unpushed no-skill agent at
`in_review`. So a finished Worker stage lands at **`in_review` (assignee = Worker)**, never `done`.
That leaves three states that look alike from the outside and need opposite actions.

## Dirty tree, 0 commits — probe liveness before concluding death

A dirty tree means "somebody is editing right now" at least as often as it means "somebody died",
and repository state alone cannot tell them apart. This is the same trap §Landing sweep has for
builds, and the same note applies verbatim: *absence of a subtask-keyed sentinel is evidence of
nothing*.

Probe three ways — a live run on the issue or its subtasks (`activeRun` non-null, or
`executionRunId` with a recent `executionLockedAt`); any process cwd'd into the worktree; recent
mtime on the dirty files. If **any** says live, do nothing and re-check next fire.

```sh
for p in /proc/[0-9]*; do
  [ "$(readlink -f $p/cwd 2>/dev/null)" = "$(readlink -f .paperclip/worktrees/{task-id})" ] \
    && echo "LIVE $(basename $p) $(tr '\0' ' ' < $p/cmdline | cut -c1-120)"
done
```

Once death is established: this is **not** an exit-gate violation and **not** a done-without-PR
case. Do not create a Reviewer subtask — its Step 0 rebase fails on unstaged changes — and do not
mark done. Re-dispatch the Worker once; its Step 0 recovery exception commits the debris with a
`Stage: worker (recovered)` trailer and continues.

## Clean tree, 0 commits — the verdict may be in the run, not the comments

Clean/0-commit is otherwise indistinguishable from never-started, which is why this arm exists at
all. A Worker that reaches a defensible conclusion and never calls `/api/` writes it to the **run**,
not to a comment — and comment-absence alone bought four full-price identical re-dispatches.

Fetch the run named by `executionRunId`, or the newest
`GET /api/companies/{companyId}/heartbeat-runs?limit=60` row whose `contextSnapshot.issueId`
matches, then `GET /api/heartbeat-runs/{runId}` and read `resultJson.result`.
(`/api/agents/:id/runs` 404s — the route is **company-scoped**; that 404 is what previously read as
"no run history exists". `GET /api/heartbeat-runs/{runId}/log` returns the full tool-call
transcript when the result is ambiguous.)

A run that `succeeded` with `exitCode: 0` and a substantive `resultJson.result` **is** the verdict
— close on it exactly as if the comment line were present. Only `status: failed`, a non-null
`signal`, or a null `resultJson` is a genuinely silent run.

A `Worker verdict:` line is terminal either way: re-firing buys the identical run at full cost.

## Architect `in_review`, branch not on origin

The verify run did cargo but never landed — the recurring Landing bug. Run §Landing sweep first;
landing is decoupled from the flaky Architect run, and that decoupling is the structural fix. Only
re-dispatch the Architect when the sweep is blocked **on cargo**, which is the one thing it can
fix. A merge conflict is never an Architect re-dispatch: it aborts on conflict and cannot resolve
one.
