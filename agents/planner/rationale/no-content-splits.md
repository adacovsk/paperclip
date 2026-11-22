# Why a content file is never split to clear contention

**Justifies:** Planner step 8, *Never a content file under `assets/data/`*; Coordinator step 5, the
content-file exception to *A file contended three times is a defect in the file*.

A content file is grouped by what it holds: spells by rank, records by pack and dataset. That grouping
is what a person or an agent goes by when finding a record, and it is the layout operator issues plan
against (pack-rooted content, per-pack members).

A split made to clear contention groups records by whatever divides the writers: the rank 1 spell
file was split into offense, support and utility files so that rank 1 spell tasks would stop queueing
behind each other. The groups have no meaning in the game, a new spell has to be placed by judgment
into one of them, and the next queue would call for the next split. The operator closed it unmerged.

Queueing on a content file costs time, not correctness: the hold serialises its writers, and each
spell task is small. That is the cost to pay. Code files keep the de-contention path, because a module
split there also gives the code a better shape.
