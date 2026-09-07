# Why the launch sources ~/.cargo/env

**Justifies:** *`cargo` is not on `PATH`* (Cargo discipline rule 10)

Without `. "$HOME/.cargo/env"` the wrapper dies instantly with `cargo: command not found` and writes **127** into the sentinel, which the old state machine read as "cargo failed" — sending the run into a 3-cycle fix loop editing Rust to chase a `PATH` bug — verify never once ran cargo, across every fire.
