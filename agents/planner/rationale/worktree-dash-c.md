# Why every git command in step 0 names the worktree

**Justifies:** step 0's `-C "$WT"` on every line, `merge` over `rebase`, `reset --hard` over `checkout -B`

Without `-C` the two arms fail in opposite directions, and the dangerous one is the arm that
*works*. The `if` arm dies on `fatal: 'planner/roadmap' is already used by worktree at ...` and
strands the fire — loud and harmless. The `else` arm used `checkout -B`, which does **not**
honour that guard: the shared checkout silently steals the branch, and the dedicated worktree's
index is left frozen at the old tree with every intervening commit staged as a deletion. A later
fire running a bare `git commit` there commits those deletions. This recurred five times; the
worst held 21 files staged and 584 deletions, enough to revert five merged PRs.

`merge`, not `rebase`: replaying a roadmap edit fails where the merge succeeds, and a failed
replay strands the fire, not the file. `reset --hard` rather than `checkout -B`: the worktree
already holds the branch, so resetting in place gets the same result without naming the branch
from outside.

Because step 0 never touches the shared checkout, there is nothing to "put back" at the end of
a fire.
