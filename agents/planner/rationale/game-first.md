# Why supply starts from the game's gaps and structural work is capped

**Justifies:** Run step 4 — *start from the game, not the code*; step 8 — *Restock from the game's
gaps first* and *A structural front is written only when it unblocks game work*; step 8a — *Game work
first*; Priority order — *Game work before structural work*

The instructions already said that shipped mechanics, not throughput, is the goal. Nothing measured
it, and the supply sources pointed the other way. In one week of merged task PRs, about 30% were
module splits and test-module moves, and about 4% implemented or wired a mechanic.

Two things produced that mix.

- **The scan finds code shape, not game gaps.** Reading four random source files turns up long files
  and misplaced tests far more readily than a missing rule, and a split of an uncontended file is
  always fileable. Floors and bands count fronts, not what they change, so splits kept the index at
  depth while the game stood still.
- **No number said whether the game moved.** Index depth, band floors and ratchet totals measure the
  pipeline. A week of splits and a week of new mechanics produced the same green dashboards.

The project's `rules-coverage` report is that number. It compares the remaster player rules the game
targets against what ships, row by row, and its gap rows are ready-made sections: each names its
records, every record is remaster by construction, and the done-when is a count that moves.
Logging its totals every fire makes progress a trend instead of an impression.

The cap keeps structural work for what it is for. A split earns its slot when it clears contention
on a file real work needs, and then it is that work's unblocker and ranks as one. Past a quarter of
the backlog, structural tasks displace game work without unblocking any. A quarter rather than zero
because some structural work is real, and a ban would push it into game tasks as unreviewed scope.
