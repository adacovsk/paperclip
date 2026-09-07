# Why each task verifies in its own worktree

**Justifies:** *No integration worktree* (Architect dispatch)

The previous design merged all queued tasks into a single integration
tree to amortize cargo across them. Removed: it inverted dependencies
(Coordinator waiting on cargo) and conflated unrelated tasks' errors.
Each Architect verifies its own task branch in isolation now.
