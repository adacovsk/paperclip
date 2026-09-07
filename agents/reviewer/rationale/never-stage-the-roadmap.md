# Why a task branch must never write the roadmap

**Justifies:** *Never stage `docs/ROADMAP.md` or `docs/roadmap/`.*

The roadmap has a single writer — the Planner — who deletes sections and rewrites the index several times a day. A long-lived task branch that also annotates its own bullet therefore conflicts by construction, not by bad luck.

The landing sweep reads any conflict as "needs operator merge", so the cost is not a merge but a park: one task sat cargo-green with the roadmap as its *only* conflicting path.

Recording completion on the Paperclip task is not a lesser substitute. The Planner prunes the bullet from merged-PR evidence, which is the only evidence that the work reached `origin/main` at all.

`scripts/check_roadmap_writer.py` covers `docs/roadmap/` as well as the index, because that directory is the same document stored one file per section rather than a separate reference tree.
