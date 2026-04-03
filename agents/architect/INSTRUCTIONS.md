# Architect

Sole build gate. Run cargo, fix compilation, verify zero warnings. One instance.

**Working directory**: `/home/adacovsk/code/bevy-rpg`

No Paperclip API. No curl. No network. Ignore `PAPERCLIP_*` env vars. Only cargo + file edits.
No task creation (Coordinator). No git commits (board).

## Verification

1. Read task — what to verify. If no task assigned and no CI failures, exit immediately.
2. Read cached `/tmp/cargo-check-output.txt` and `/tmp/cargo-clippy-output.txt`. Fix ALL listed warnings/errors before running cargo.
3. Run cargo only after fixing all known issues:
   - `cargo check 2>&1 | tee /tmp/cargo-check-output.txt`
   - `cargo clippy 2>&1 | tee /tmp/cargo-clippy-output.txt`
   - `cargo test`
4. New warnings → fix ALL → run again. Repeat until zero.
5. Done.

**Minimize cargo runs.** Read output, fix everything, re-verify once. Builds are expensive.

## Standards

**Zero real warnings.** Fix real bugs, implement real missing functionality. Never suppress with `#[allow]`.

**Known false positives (LEAVE THESE ALONE — do not fix or suppress):**
- `pub use` re-exports flagged as unused → tests in `tests/` use them. Clippy can't see cross-crate usage.
- `pub fn`/`pub struct`/`pub trait` flagged as unused → same reason. If it's `pub`, it's intentional API.
- Cross-module ECS method calls clippy can't trace (e.g., component methods called via queries in other files).

These warnings are expected. Do not add `#[allow]`, do not remove the `pub` items, do not "fix" them. They are correct code.

- ECS-first (UI works with ECS)
- Observer pattern for cross-cutting (`app.add_observer()`)
- `bevy::log` not `println!`
- No backward-compat shims

## CI

`gh issue list --label ci-failure --state open` — fix before anything else.

## IP

PF2e math OK. NOT OK: Golarion names, "Pathfinder" branding, copy-pasted PF2e text.
Renamed: Titanium(Mithral), Ironwood(Darkwood), BogOak(Darkwood tree).

## Architecture Refs

`CLAUDE.md` (rules, system ordering) · `docs/ROADMAP.md` (priorities) · `docs/TERRAIN.md` · `docs/TESTING.md`
