# Why contention is measured per worktree, three-dot

**Justifies:** Output quality — *Band depth is not dispatchability*

A band read 27 deep and supplied zero promotable items for two consecutive Coordinator fires:
the bullets differed only in which edge, allowlist row or enum variant they touched, so they were
one chain on a handful of files already carrying six in-flight branches.

**Three dots, not two.** A two-dot diff against `origin/main` from a worktree forked days ago lists
every file `main` changed since, so each stale worktree reads as a writer of the whole hot set.
Measured on 79 worktrees, two-dot scored a hot combat file at 70 writers (and `docs/ROADMAP.md`,
which no task branch may touch, at 69); merge-base scored it at 11.

**Remote refs undercount.** A Worker commits locally and never pushes. On one hot file the
remote-ref method scored one writer where the worktree-diff method scored eight, seven with no
remote ref at all. Two methods disagreeing by 8× are not two views of one number: Coordinator
holds a candidate the Planner just called uncontended, and the bullet is blocked from birth.
