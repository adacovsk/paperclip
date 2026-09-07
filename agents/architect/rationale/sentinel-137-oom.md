# Why an OOM kill is remapped to 137

**Justifies:** *the build was OOM-killed, NOT a build failure* (Procedure — sentinel state machine, `137`)

137 is 128+9: the launch found `signal: 9` in *this run's* log, meaning the OOM killer SIGKILLed rustc mid-compile. cargo reports that as `error: could not compile … (lib test)` and exits **101 — the same code a genuine test failure produces** — with no `error[Exxx]`, no failing test names, no `test result: FAILED`; the only tell is `(signal: 9, SIGKILL: kill)` buried in the `Caused by:` tail. It is remapped here precisely because, read as 101, it sends you hunting a bug that does not exist in your diff (that already cost a cycle on one task). Your code is very likely fine. Do **not** enter the fix loop and do **not** edit Rust. `rm -f "$EXIT"` and relaunch: the `--test` compile of `src/lib.rs` is the heaviest unit in the build, so it dies when several verifies reach that stage at once, and a retry on a quieter box usually just passes.
