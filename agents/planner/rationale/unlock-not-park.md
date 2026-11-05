# Why a missing mechanic becomes an unlock section, not a parked bullet

**Justifies:** Run step 8 — *A row that needs a missing mechanic is supply, not a park*; Output
quality — *Unlock a missing mechanic*; Fire budget — *step 8 joins the spine*

Allowlist debt is the project's largest standing supply: each row is a rule the game does not yet
implement. A row can leave its allowlist only when its effect is implemented, so a row whose effect
needs a mechanic that does not exist cannot be cleared on its own. The Planner answered that by
rewriting the owning section's index bullet to say the rows were parked and must not be filed.

That turned supply into a dead end in three ways.

- **Nothing built the mechanic.** The park named what was missing and stopped. About two hundred
  rows across six allowlists sat behind roughly ten missing mechanics, each a real rule with a
  remaster record, and no section ever proposed building one.
- **The index read as full.** A park written in prose carries no hold marker, so the roadmap check
  counted every parked bullet as free depth. The index reported 63 free fronts on the same fire
  that the claims check found none fileable. The floor read as met, so restock never ran.
- **Restock was optional.** Writing new sections was fill, taken only after pruning and filing.
  Fire after fire the summary read "out of supply" and "restock not reached", while the Workers ran
  2 of 12 slots.

Building the mechanic and clearing its rows in one PR fixes the first. It is also the only shape
the project's rules allow for either half: a mechanic with no caller warns `dead_code`, which may
not be suppressed, and a row may not be cleared by substituting a key that already resolves. The
rows give the mechanic its first callers, and the shrink-only allowlist proves the behaviour
shipped. When the rows outgrow one Worker run the chain carries them, so it still lands as one PR
and one build; Step 1 never builds the mechanic alone, because that branch would carry the
unused code the rule forbids.

Banning prose parks fixes the second. A front that cannot be filed either becomes an unlock
section, waits on the operator under the one hold marker the roadmap check understands, or leaves
the index with its reason recorded in the detail file. Whatever stays in the index is fileable.

Making restock part of the spine when step 8a ends short fixes the third. An index that cannot fill
the backlog idles every Worker slot, which costs more than any fill step buys. The leaky-queue brake
still applies: at least one new section is the brake's own allowance, so the two agree.
