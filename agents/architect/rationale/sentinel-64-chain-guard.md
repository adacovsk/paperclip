# Why cargo-sem.sh refuses a chained invocation

**Justifies:** *refused the invocation, NOT a build failure* (Procedure — sentinel state machine, `64`)

Chaining several cargo commands inside one slot acquisition holds that slot for the whole
chain, which is the failure the one-cargo-per-call rule exists to prevent.

The wrapper refuses it outright rather than running it, so this code means cargo never
executed. The code is fine; the command was malformed.

That distinction is the reason for a dedicated code. Any non-zero exit otherwise reads as a
build failure, and a build failure reads as an instruction to edit source — so a
malformed *command* would be answered by changing *code* that was never compiled, consuming
the fix budget on a defect that is not there.

The correct response is to re-read the launch and confirm the chaining operator sits between
invocations rather than inside one. A refusal that persists against a correctly split command
means something is rewriting it, which is a different problem and not one to solve by editing
source either.
