# Why the reap sentinel is written before the kill

**Justifies:** *the build was deliberately reaped; the task could not consume the result* (Procedure — sentinel state machine, `100`)

- **Why this code exists at all.** The reap writes it first precisely so the wrapper's own `_sentinel` trap — which only fires when the file is absent — cannot overwrite it with `99`. Without that ordering every reap produced `99`, `99` means relaunch, and the next wake started the build again: the reap would cost a full build and free nothing. `137` has the same failure shape via the launch block's `signal: (9|15)` remap. If you see `100`, the slot was freed on purpose; re-taking it needs a reason.
