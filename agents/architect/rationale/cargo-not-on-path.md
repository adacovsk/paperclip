# Why the launch sources the cargo environment

**Justifies:** *`cargo` is not on `PATH`* (Cargo discipline rule 10)

The runner's shell is neither login nor interactive, so it sources none of the profile files
that would put the toolchain on `PATH`. It inherits the daemon's environment instead — and
that environment is a snapshot from whenever the daemon last restarted, not from what the
profile says today.

Without the explicit source, the wrapper dies immediately with a command-not-found. The exit
code for that is generic, and read as a cargo result it means "the build failed" — so the run
enters its fix loop and spends the whole budget editing source to chase what is actually a
`PATH` problem. Cargo never ran at all, so nothing the loop does can change the outcome, and
the same thing happens on every subsequent attempt.

Hence the distinct environment sentinel: a missing toolchain and a failing compile need to be
different states before anything reacts to them.
