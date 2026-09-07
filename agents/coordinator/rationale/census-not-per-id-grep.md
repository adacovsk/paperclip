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
