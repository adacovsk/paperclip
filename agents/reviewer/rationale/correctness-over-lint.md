# Hunt defects, not lint

**Justifies:** *Cosmetic fixes come after the defect pass, never instead of it.* and *Fast exit, only for diffs with no behaviour in them.* and *Read outside the diff before judging it.*

## What the stage was actually buying

Measured over two weeks of merged task PRs: the Reviewer committed on roughly three in five of them, but the commits split very unevenly by value.

- **The catches that justify the stage** were correctness defects nothing downstream would find: a trigger that never carried the field its guard read, an AI action that dropped its target, a disposition shift that cost nothing, a resistance bypass keyed on the wrong damage type, an allowlist line cleared by re-pointing a key at an existing alias (reverted by the Reviewer). These compile, pass clippy, and often pass tests. The Architect's cargo run cannot see them; only a reader comparing the diff to the task can.
- **The bulk** was import reordering, rustfmt wraps, blank lines, and comment rewording. It was cheap to make but not free to pay for, because the Reviewer is the most expensive stage per run. A fresh session reads the whole diff at depth either way.

The old checklist (helpers over inline math, `find_nearby`, unused imports, `println!`, SystemParam) steered attention to the bulk. Every item on it is already a project rule the Worker writes under, and most are things clippy or the Architect's fix loop catch anyway, so the Reviewer mostly found nothing or found cosmetics.

## Why cosmetic fixes come second, not never

Cosmetic fixes are cheap and the operator is fine receiving them. The failure is ordering: a review that stops once it has found something to polish reads as productive while the correctness pass never happened. So cosmetics are allowed, but only after the defect checklist has been done.

## Why a fast exit, and why it is narrow

Some diffs carry no behaviour: an allowlist reason, a comment, a rename. A full procedure plus a long completion essay spends the same tokens as a large task to say "looks right", so those exit after one read.

The exit used to cover "small and mechanical" diffs, including one-line fixes and a few data rows, on the reasoning that defects in a small diff show at a glance. That holds only for defects visible *in* the diff. A one-line fix can be correct on its line and wrong for its caller, and a data row can be well-formed and land on no field. Reviews were finishing in under a minute, which is one read of the diff and nothing else. Size is not the test; whether the diff changes behaviour is.

The exit is **not** for data diffs as a class. Data-only PRs produce real catches too: re-authored feat text that no longer matched the rules, a key moved onto the wrong class, a ratchet line cleared by substitution.

## Why read outside the diff

The catches listed above that justify this stage are mostly invisible from the diff: "a trigger that never carried the field its guard read" is found by opening the trigger, and "nothing in production sets this" by grepping for a writer. An earlier version told the Reviewer not to open surrounding files, to stop it hunting for something to say. That also stopped it doing the reads the checklist depends on. The fix is to name the reads, so the Reviewer does them every time and only them, rather than ban reading.
