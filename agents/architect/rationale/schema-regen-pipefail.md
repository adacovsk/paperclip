# Why the schema regeneration is one chained command

**Justifies:** *The `set -o pipefail` and the `&&` are both load-bearing* (Procedure step 6.5)

**The `set -o pipefail` and the `&&` are both load-bearing — do not drop either back to two plain statements.** Without `pipefail` the pipeline's status is `tee`'s, which is 0 whatever the generator did; without the `&&` the `git diff` runs regardless. Either way a generator that never produced a file reports a clean tree, because *nothing was written* is indistinguishable from *nothing changed* by the diff alone. That is not hypothetical: the generator exits 101 on `No space left on device` (`target/` reaches ~28 GB against a fixed allowance; `cargo clean -p the crate` frees it), and read as "clean" it let stale schemas reach `main` twice — see root `CLAUDE.md`, a PR. Chain it so a failed generator cannot be read as a clean tree.
