# Why a contended edit surface is a scheduling decision

**Justifies:** *Hold on a contended edit surface.* (Run step 5)

This is not hypothetical scheduling theory. Seven branches went unmergeable at once, and **six of them were the same kind of work** — adding a usage-limit/frequency gate to one more `AbilityMechanic` variant — so they necessarily all edited the same two `src/systems/` files. Main then absorbed two more commits on that same surface and every in-flight branch broke together. The pipeline read that as six independent "needs operator merge" parks, billing six hand-merges for one scheduling decision.
**Same-shaped work is the tell.** If two roadmap bullets differ only in *which variant or entry* they handle, they share a dispatch surface — treat them as one chain, not as parallel work. Promote one; promote the next when the first merges.
