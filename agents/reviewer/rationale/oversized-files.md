# Oversized files: report the split, don't make it

**Justifies:** *Oversized files (over ~1000 lines): report, don't split.*

## Why it is not the Reviewer's to do inline

- **It buries the task.** A 1,600-line file split into six modules is a diff nobody can review alongside the two-line fix it arrived with, and the operator's veto at PR review is the only veto there is.
- **It collides by construction.** These are the busiest files in the tree, so several task branches are usually inside one at once. Measure before proposing:

  ```sh
  for w in .paperclip/worktrees/*/; do
    git -C "$w" diff --name-only "$(git -C "$w" merge-base origin/main HEAD)"..HEAD
  done | sort | uniq -c | sort -rn
  ```

  A file that two or more live branches are already editing is not a candidate this week, whatever its size. Say so in the issue rather than filing it as ready.
- **Size alone is not a defect.** 79 of 596 `.rs` files are over 1000 lines, so the threshold selects an eighth of the tree and cannot mean "all of these are wrong". The ones worth splitting are those where the length tracks *several unrelated concerns* sharing a file. A long file doing one thing thoroughly (a single exhaustive `match`, a generated table) is fine. Name the concerns you would separate; if you cannot name them, there is no split to make.

## `tests/` splits too, and is usually the better candidate

Do **not** exempt a file for living under `tests/`. The four largest files in the repo are test modules, and they are also the *least* contended: measured across the live worktrees, no test file had more than one branch in it while one system module had five.

The seams are already named. The big test files are a stack of inline `mod <name>_tests { ... }` blocks (one integration suite is 5983 lines holding **39** of them). One block becomes one file, so the move is mechanical.

**The layout differs from `src/`, and getting it wrong is silent.** Cargo builds one integration-test binary per *file* directly under `tests/`, so `foo/mod.rs` is not the pattern:

```
tests/foo.rs                 ->   tests/foo/main.rs        (the target, still named `foo`)
    mod alpha_tests { .. }   ->   tests/foo/alpha_tests.rs (declared `mod alpha_tests;`)  <!-- privacy-ok: placeholder module name in an illustration -->
```

Subdirectories under `tests/` are not compiled as their own targets, so the submodule files do not become stray test binaries. Keep module names byte-identical: a test's full path is its filter, so renaming a block silently breaks `cargo test <filter>`.

## The shape of a split

`foo.rs` becomes `foo/mod.rs` plus one submodule per concern, with `mod.rs` re-exporting the previous public surface so no caller outside the module changes. **Move items, never retype them.** A retyped system loses its run condition or its `.chain()` ordering silently, and a dropped run condition is worse than the file being long. Slice one concern at a time; moving a whole file at once is itself a contention event.

**The one case a Reviewer may do it inline**: the task already restructures that file, the move is mechanical, and no public path changes because `mod.rs` re-exports what the file exported.
