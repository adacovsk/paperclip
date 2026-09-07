# Why the roadmap has one writer branch

**Justifies:** *Why this is a rule and not a preference* — the single `planner/roadmap` writer branch

**Why this is a rule and not a preference.** Minting a name per fire produced sixteen live `planner/*` branches — five in one day — two of which carried overlapping restocks committed hours apart, and one of which (`planner/prune-0826e`) sat 376 commits behind `main` with every one of its edits already landed by a later fire that had forked separately. A second writer branch collides on the `## Active fronts` index exactly as a task branch does, with the added cost that neither side is wrong, so there is nothing to discard. Step 11 already tells you to resume an interrupted fire "from the existing branch instead of silently redoing the work onto a conflicting parallel branch" — this is the branch it means.
