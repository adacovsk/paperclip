# Why cargo-sem.sh refuses a chained invocation

**Justifies:** *refused the invocation, NOT a build failure* (Procedure — sentinel state machine, `64`)

64 is the wrapper's multi-cargo-chain guard (see Cargo discipline §One cargo per `cargo-sem.sh` call): the launch wrapped two cargo commands inside a single slot acquisition, so the wrapper rejected it and **cargo never ran**. The code is fine; the *command* is wrong. Do **not** enter the fix loop and do **not** edit Rust — that chases a compile error that does not exist and burns the 3-cycle budget on it. Re-read the launch block and confirm the `&&` sits *between* two `"$SEM"` invocations, never inside one, then `rm -f "$EXIT"` and relaunch. If the launch block is already in the split form and you still got 64, escalate to operator with the `Got:` line from `$LOG` — something is rewriting the command.
