# Why a clean 0-commit exit needs its own arm

**Justifies:** *if absent, read the run's `resultJson.result` before re-dispatching* (Run step 3)

A run that finishes having changed nothing leaves the same repository state as a run that
never started: clean tree, no commits, no branch movement. Nothing in the tree distinguishes
"there was nothing to do" from "the dispatch failed".

Without an arm that reads the run's own verdict, the sweep can only guess, and the safe-looking
guess is to re-dispatch. That buys the identical no-op at full price, and it can repeat several
times inside a short window, because each re-dispatch re-establishes exactly the state that
triggered it.

The verdict has to come from the run rather than from the tree — a comment line, or the run
record itself. Only a run that genuinely failed to report is worth firing again.
