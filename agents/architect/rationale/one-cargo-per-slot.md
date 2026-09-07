# One cargo per slot, and the resume lane

**Justifies:** *One cargo per `cargo-sem.sh` call — never chain*, and the claim that yielding the slot between stages is free. (Cargo discipline rule 3)

**Why chaining is the single worst thing you can do to this queue.** A slot is held for the whole lifetime of the wrapped command, so `cargo-sem.sh bash -c 'cargo clippy && cargo test --lib'` holds ONE slot for an entire verify. Measured: one such chain held a slot 3–7 hours while the front waiter sat 9h50m.

That is why starvation kept recurring *after* the ticket queue made admission provably fair. Fairness was never the problem; hold time was. Two separate calls each wait their own turn and yield the slot in between, which is what lets the queue drain. It is also why "one cargo at a time" and the staged gate are compatible with the semaphore rather than in tension with it: you were always meant to run clippy, let go, then run test.

**Why yielding became free.** Yielding the slot between stages used to send a half-finished verify to the back of the queue — measured, a clippy result sat complete and unused for 3h26m while its `test --lib` waited, and a verify paid 3–4 full queue drains. That was the real cost behind "verifies are slow", and it made chaining look attractive for the wrong reason. The resume lane removed that cost, which is what makes the no-chaining rule cheap to obey.
