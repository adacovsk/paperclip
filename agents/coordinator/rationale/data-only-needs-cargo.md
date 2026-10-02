# Why a data-only change can still need cargo

**Justifies:** the *Reviewer done, `data-only`, diff touches data Rust loads* row of the stage
table.

## The failure

`data-only` meant "no cargo", because no Rust changed. But the crate's unit tests read the shipped
data: `MonsterDataResource::load_shipped()`, `*::load_from_file()`, the `.ftl` bundles. A data
change can therefore fail `cargo test --lib` with no Rust touched, and nothing on the `data-only`
path ever ran it.

That is how a monster re-levelling reached `main`. It moved `zombie_shambler` to level -1, where
its hit-point band is a single value. A variance test picks the highest-id monster and asserts its
HP spreads, so the test now failed. The PR's Verification section said, accurately, "data-only: no
cargo run (no Rust changed)". The weekly CI run found it days later, alongside two unrelated
breaks, so the three had to be untangled at once.

## Why decide by the diff

The label is assigned at intake from the roadmap bullet's stated paths, before any work exists.
The Worker's actual diff is what matters, and it can reach files the bullet never named. Deciding
at step 3 from `git diff --name-only origin/main...HEAD` uses the only evidence that describes
the change.

## Why only `assets/data/**` and `assets/locales/**`

These are the trees Rust deserialises at test time. `scripts/**`, `docs/**` and
`.github/workflows/**` are not loaded by the crate, so a change confined to them still lands
without cargo. That keeps pure guard work and prose off the cargo lock, which is what the
`data-only` label exists to do.
