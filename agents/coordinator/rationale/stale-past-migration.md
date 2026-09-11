# Why modify/delete is not a merge conflict

**Justifies:** *has no second version to reconcile, so "needs operator merge" is unreachable by construction* (§Landing sweep step 3)

When `merge-tree` reports `CONFLICT (modify/delete)` and the **deleted** side is `origin/main`,
the branch edits a file that no longer exists upstream. There is no second version to reconcile,
so "needs operator merge" is unreachable *by construction* — there is no merge to perform. A hand
resolution would resurrect a file the current loader does not read, and silently revert the
migration commit that removed it.

The disposition is therefore to cancel and re-file against the new layout, carrying the original
description over verbatim. Re-authoring is nearly always cheaper than reconciling against a
structure that is gone. Six such branches sat `blocked` for ~19 days on the wrong disposition
before anyone checked whether the merge they were waiting for could exist at all.

A green cargo sentinel on such a branch attests to a **pre-migration tree shape** and is evidence
of nothing. Confirm freshness with
`git merge-base --is-ancestor $(cat "$VERIFY_DIR/{task-id}.base") origin/main` before treating any
`.exit` as current.
