# Why an OOM kill is remapped to 137

**Justifies:** *the build was OOM-killed, NOT a build failure* (Procedure — sentinel state machine, `137`)

An out-of-memory kill and a genuine test failure reach cargo as the same exit code, and cargo
surfaces both identically. There is no error code, no failing test name, no failure summary —
the only distinguishing evidence is a signal mention buried in the cause chain.

Read at face value, that sends the run hunting a bug that does not exist in its diff, and the
budget for real fixes is spent proving the code correct.

The remap exists so the two are different states before anything acts on them. Recognising it
early also matters because the correct response is the opposite of a fix: the compile that
dies is the heaviest unit in the build, it dies under memory pressure from concurrent builds
rather than from anything in the change, and a retry on a quieter machine usually passes
unmodified.

A termination signal is a different cause again — deliberate rather than resource-driven — and
conflating the two loses that distinction.
