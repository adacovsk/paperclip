# Hunt defects, not lint

**Justifies:** *Cosmetic fixes come after the defect pass, never instead of it.* and *Fast exit for small, mechanical diffs.*

## What the stage was actually buying

Measured over two weeks of merged task PRs: the Reviewer committed on roughly three in five of them, but the commits split very unevenly by value.

- **The catches that justify the stage** were correctness defects nothing downstream would find: a trigger that never carried the field its guard read, an AI action that dropped its target, a disposition shift that cost nothing, a resistance bypass keyed on the wrong damage type, an allowlist line cleared by re-pointing a key at an existing alias (reverted by the Reviewer). These compile, pass clippy, and often pass tests. The Architect's cargo run cannot see them; only a reader comparing the diff to the task can.
- **The bulk** was import reordering, rustfmt wraps, blank lines, and comment rewording. It was cheap to make but not free to pay for, because the Reviewer is the most expensive stage per run. A fresh session reads the whole diff at depth either way.

The old checklist (helpers over inline math, `find_nearby`, unused imports, `println!`, SystemParam) steered attention to the bulk. Every item on it is already a project rule the Worker writes under, and most are things clippy or the Architect's fix loop catch anyway, so the Reviewer mostly found nothing or found cosmetics.

## Why cosmetic fixes come second, not never

Cosmetic fixes are cheap and the operator is fine receiving them. The failure is ordering: a review that stops once it has found something to polish reads as productive while the correctness pass never happened. So cosmetics are allowed, but only after the defect checklist has been done.

## Why a fast exit

Many diffs are small and mechanical: one allowlist reason, a handful of data rows, a one-line fix. The defect classes above either appear in those diffs at a glance or not at all. A full procedure plus a long completion essay spends the same tokens as a large task to say "looks right".

The fast exit is **not** for data diffs as a class. Data-only PRs produce real catches too: re-authored feat text that no longer matched the rules, a key moved onto the wrong class, a ratchet line cleared by substitution. The deciding factor is size and mechanicalness, not the label.
