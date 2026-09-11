# Why liveness is a census, not a per-id grep

**Justifies:** *Take the census once, for every id — never `pgrep`/`grep` per task.* (Landing sweep)

Filtering a process list for one build's tag matches the filtering command itself, because that
command's own arguments contain the tag. The probe observes its own presence and reports the
build alive whether or not it exists.

Inside a loop it degrades further. The loop shell's arguments hold every id being checked, so
every probe matches, an entire sweep reads as fully alive, and nothing is ever re-dispatched —
a silent failure that looks like a healthy pipeline.

Taking one census over all ids removes the self-match, because the reading is no longer made
per id.

This is the same failure as the sentinel probe approached from the other side. Sentinel
probing calls live builds dead; a per-id grep calls dead builds live. Both come from asking a
question whose answer depends on the act of asking.

## Two further refinements, both measured

**Take the scope list, not `ps` alone.** A wrapper launched through
`~/.cache/paperclip-verify/run-AA-<id>.sh` has argv
`/usr/bin/setsid bash /home/.../run-AA-<id>.sh` — the `verifyrun-AA-<id>` token lives *inside the
script file*, so a `grep` over `ps` output cannot see it and the build reads as dead. Measured: 17
systemd scopes against 16 argv rows, and the one dropped row was a live build that had finished
clippy and was queued 2h38m for its `test` slot. Re-dispatching it would have discarded that work.
The scope name carries the id for **both** launch forms, which is why it is the primary source;
`ps` stays in the union to cover a wrapper whose scope registration failed.

**Require one-or-more digits (`[0-9]+`), not `[0-9]*`.** With `*` the pattern matches zero digits
against the literal `verifyrun-AA-[0-9]*` in the pipeline's own argv, and the census grows a
phantom bare `verifyrun-AA-` row — 10 of them, measured on this box.

Membership in that one set is the liveness answer for every task in the sweep, and it is read in
two places that fail in opposite directions: an under-read kills a live build in §Landing sweep,
and the same under-read over-dispatches in §Architect dispatch's cap.
