# Why sentinel 99 exists

**Justifies:** *the wrapper was signalled before cargo reported — INCONCLUSIVE, not a build failure* (Procedure — sentinel state machine, `99`)

- **The trap exists because the old failure mode was silence.** A killed wrapper wrote nothing at all, and "no sentinel + dead pid" is indistinguishable from "still building" — Coordinator's sweep skipped those tasks every fire while the work stranded, and a re-dispatch re-paid the full ~3h compile. `99` is what turns that into a legible, actionable state. A SIGKILL still cannot be trapped; that is what the transient scope in the launch block is for.
