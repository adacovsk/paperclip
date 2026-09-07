# Why the schema trigger is the guard script, not a path prefix

**Justifies:** *Do not re-narrow this trigger to a path prefix* (Procedure step 6.5)

"Which files can move a generated schema?" has exactly one correct answer, and it is derived,
not enumerated. The guard computes it by starting from the generator's own imports and
following use-edges outward, so the set includes anything transitively reachable from a schema
root.

A path prefix is a hand-maintained approximation of that set, and always a strict subset of it.
Types reachable from the generator live under several directories, so a prefix covering one of
them misses the rest.

The failure mode is the expensive kind. A change under an uncovered path skips regeneration,
the branch goes green locally, and CI rejects it for drift the diff never suggested — with the
work otherwise finished, so this is the only thing standing between it and a merge.

The deeper problem is having two definitions of the same thing. The prefix drifts out from
under the guard silently, because nothing compares them. Running the guard itself removes the
second definition entirely: there is one answer, and the check that enforces it is the check
that computes it.
