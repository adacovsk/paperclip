# Why a rebase dispatch must be a new task, not a comment

**Justifies:** *A rebase dispatch must be a NEW task* (§Landing sweep step 3)

The Worker reads its task from the **injected prompt**. It does not read the comment thread, and
it has no API with which to — Workers carry no skills and no Paperclip access by design.

So a dispatch whose only instruction is a comment saying "rebase this branch and resolve `<path>`"
is literally invisible to the agent it is addressed to. Three such runs on one task each exited
`succeeded`, reporting the *implementation* complete — which it was — while the rebase they were
dispatched for never happened. Every signal read like success.

The instruction has to be in the task **description**, and it has to say not to re-implement, or
the Worker reads a task about a finished branch as a request to write it again.

Worker Step 0 carries the matching arm ("Step 0 does not apply to a rebase task"), so the two
halves only work together: changing one without the other re-breaks this.
