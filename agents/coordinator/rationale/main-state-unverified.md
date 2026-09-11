# Why an empty `ci-failure` list is evidence of nothing

**Justifies:** *An empty `ci-failure` list is evidence of nothing, and must never be recorded as "main is GREEN"* (Run step 2)

`ci.yml` has no `push: main` trigger — deliberately, to conserve Actions minutes. So nothing ever
evaluates `main` itself, and a break that lands via a merge whose PR checks predated it files no
issue at all. An empty `ci-failure` list therefore means "nobody looked", not "it is green".

Observed: a duplicate top-level type (`E0428`/`E0119`) sat on `main` for ~5 hours while consecutive
routine records asserted GREEN on the strength of the empty list. Five verify builds rebased onto
the poisoned base in that window.

The cost is worse than a wrong label. A fire that believes `main` is green does not look for a
ci-fix, and reads the resulting build failures as **task** defects — which is what sends a Worker
to rebase a branch that was never broken.

Hence the three-way record. Writing `main state: unverified (no ci-failure issues open; no positive
check run)` is cheap and honest, and it is what lets the next fire tell "nobody looked" apart from
"somebody looked and it was fine". The two things that *do* license a green assertion are a cargo
result against a `main`-rooted tree, or a source read of the suspect path — and the record must
cite which one was run, because an uncited assertion is indistinguishable from the empty-list
reading this rule exists to kill.
