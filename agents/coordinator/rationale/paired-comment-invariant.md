# Why a status write without its reason is not allowed

**Justifies:** *Every `status` PATCH you make carries its reason.* (§Status writes)

## Why the reason is load-bearing, not bookkeeping

A `blocked` with no comment is unrecoverable by every downstream consumer *including this sweep*.
Facilitator §2 clears a blocker by reading the latest comment to identify it; when the newest
comment predates the block by days, there is no way to tell a live blocker from a stale flip.

Measured: eight tasks flipped to `blocked` inside 73 seconds with no comment on any of them, their
newest comments 1–10 days old — and one of those comments recorded that the task had already been
*unblocked*. Nothing can re-clear that state without guessing.

That 73-second batch is also the shape rule 1 names: a sweep iterating a list writing `status`
without a paired `comment`.

## Which call to use, and the fallback order

The project `CLAUDE.md` records that a `comment` field alongside a status PATCH **500s** and that
operators should post the comment separately. Probed against the live server while writing this,
the combined PATCH returned **200 and the comment landed** — so that note is stale or
condition-specific, plausibly the concurrency race below rather than an unconditional refusal.

Treat the combined form as preferred but not guaranteed. If it errors, `POST
/api/issues/{id}/comments` **first**, confirm the `201`, and only then PATCH the status. The order
matters because the failure is *asymmetric*: under a tight loop of comment-then-status writes, the
comment insert is the half that rolls back, so the status advances and the record vanishes.
Writing the reason first is what makes a partial failure recoverable.

## Why clearing a block requires a quote

The rule "never revert a block you did not author" was already stated at §Landing sweep step 3.
What kept failing was that the sweep never performed the read — so the requirement is now to make
the read **observable** by quoting the block comment and naming what resolved it.

A pass that pattern-matched "the last comment declares it released" reverted five blocks in one
sweep and every one was wrong; three were conflict-class tasks that then relaunched Architects onto
branches that provably could not merge.

## Why direction, not presence

Status *language* is not a clearance. "blocked on red main", "needs operator merge", "waiting on
AA-nnnn" all contain status words and all point the opposite way. Reading presence instead of
direction flipped two live blocks to `in_review` and cost four runs — two to make the bad flips,
two to detect and revert them.

Where a comment is ambiguous, surface the task in the record and leave it untouched. Leaving a
status alone is always available and always safe.

## Why `description` is write-once

A fire once wrote its sweep record into a live task's `description`. The original body was
destroyed: that task now ends mid-path in its `Where` list and has **no `Done-when` at all**, so a
Worker dispatched on it cannot tell when it is finished.

The damage is permanent — `description` has no version history exposed through the API — and the
partial recovery that was possible only worked because an earlier run happened to have quoted the
body in a comment, truncated at 900 characters. It is also invisible: the issues *list* endpoint
omits `description` entirely, so an overwritten task and a normal one look identical unless you
fetch the single issue.
