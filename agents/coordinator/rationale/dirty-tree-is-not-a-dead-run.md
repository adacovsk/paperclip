# Why a dirty worktree needs a liveness probe

**Justifies:** *Probe liveness first* — the dirty-tree/0-commit arm (Run step 3)

A dirty worktree with no commits has two completely different causes, and the repository
cannot tell you which one you are looking at. A run may have died partway through its edits,
or a run may be making those edits right now. The tree looks identical either way.

The stages share one worktree, so the edits a sweep reads as abandoned Worker debris are just
as likely to be the Reviewer's work in progress. Concluding death from state alone therefore
cancels live stages and re-dispatches over the top of them.

Both consequences are worse than the problem being fixed. An agent that honours the
cancellation loses uncommitted work outright, and the re-dispatch races the run still holding
the worktree, where the two builds deadlock on the shared target directory.

Liveness is observable — a run record, a process whose working directory is that worktree, a
recent write to the files themselves — so it should be observed rather than inferred. The
governing asymmetry: waiting one cycle on a genuinely dead run costs a cycle, while acting on
a live one destroys work.
