# Why an open PR still needs the verified tip pushed

**Justifies:** *publish the verified tip if the PR does not already carry it* (§Landing sweep step 4, the Open PR and Nothing at all cases)

## The failure

When a PR's branch conflicts, the Coordinator dispatches a Worker rebase. The Worker rebases
`task/{task-id}` onto `origin/main` in its worktree, and its done-when (`merge-tree` exits 0) is
checked against that local branch. The Architect then verifies the local tip. But step 4 read
"Open PR → nothing to do" and "skip the push if the branch is already on origin". So the rebased
and verified tip never left the box, and the PR kept its old pre-rebase head.

The result looked healthy from inside the pipeline and broken from outside. The sweep's
clean-merge gate passed every fire, because it tested the local branch. GitHub showed the PR as
`CONFLICTING`, because it tests the pushed head. Eight PRs sat in that state at once. Three of
them had a green sentinel for a tip that GitHub had never seen.

## Why a merge and not a force-push

A rebase rewrites the branch, so the verified tip is not a descendant of the PR head, and
publishing it plainly would need `--force`. A force-push to a branch under review discards the
history a reviewer has already read, and the permission layer refuses it as destructive. The
`-s ours` + `read-tree` merge sidesteps both problems. The new commit's tree is byte-for-byte the
tree that was verified, so nothing unverified is published, and its first parent is the old PR
head, so the push is a fast-forward.
