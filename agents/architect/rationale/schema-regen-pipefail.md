# Why the schema regeneration is one chained command

**Justifies:** *The `set -o pipefail` and the `&&` are both load-bearing* (Procedure step 6.5)

The check is "did regenerating change anything?", and a diff answers it by comparing files. But
*nothing was written* and *nothing changed* produce the same empty diff, so a generator that
never ran reads as a clean tree.

Both pieces close that gap from different sides. Piping through `tee` replaces the generator's
exit status with the pipe's, which succeeds regardless of what the generator did; `pipefail`
restores it. Running the diff as a separate statement executes it whatever happened before;
chaining with `&&` makes a failed generator stop the check rather than pass it.

Written as two plain statements, the sequence reports success most reliably exactly when it has
done the least. The generator fails for environmental reasons that have nothing to do with the
change — running out of disk is the common one — so this is not a rare path, and its symptom is
a green result that means nothing was verified.
