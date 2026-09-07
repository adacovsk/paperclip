# Why the two capacity gates stay separate

**Justifies:** *Do not "simplify" this by folding `inflight` into the first gate.* (Run step 9a)

The two gates answer different questions and act on different things. `ready` asks whether
un-started work exists, and blocks intake outright. `inflight` asks whether the build lock is
saturated, and restricts intake to work that never touches it.

An Architect-bound pipeline sits at many `in_review` parents as its normal condition, not as a
symptom. Summing the two counts into one threshold therefore crosses it on essentially every
fire, and intake stops running at all — starving supply exactly when the Planner has restocked
it.

The trap is that an under-count of in-flight work looks like it should be fixed by counting
in-flight work in the main gate. That reading is right about the symptom and wrong about the
remedy: `inflight` needs to select *what kind* of work is promoted, never to decide *whether*
promotion happens.
