# Why three-time contention escalates to Planner

**Justifies:** *A file contended three times is a defect in the file, not in the schedule.* (Run step 5)

Both prior instances were fixed by removing the contention outright rather than by scheduling around it: the `validate-data.yml` per-guard step list became `run_guards.py` auto-discovery, so adding a guard needs no workflow edit at all; and `docs/ROADMAP.md` was given a single writer, enforced by `scripts/check_roadmap_writer.py`. `assets.manifest.json` is the open one.
