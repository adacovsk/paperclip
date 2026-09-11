# Why a sweep must read the block it is about to clear

**Justifies:** *Never revert a block you are not the most recent author of* (§Landing sweep step 3)

A sweep that decides whether a block still holds by re-testing its **own** predicate — the
parent's status, a stale conflict, an idle window — will happily overwrite a newer block written
by someone else for a different reason, because it never read that reason.

Observed: a sweep unblocked on parent status alone and cleared a set of tasks blocked for an
entirely different cause — a broken base that no branch could compile against. The comment
directly above said red `main`, and was not read; it had been written by an earlier pass of the
same sweep and was replayed over by the newer one. All seven relaunched onto a still-red `main`,
burned 575–1038 log lines of compile apiece, exited `99`, and competed for `cargo-sem.sh` slots
with the ci-fix repairing the very breakage that doomed them.

The general form: without this rule every block is provisional until some sweep happens to
disagree, and there is no durable way to say "do not build this yet".

**Do not work around it by blocking the parent** to make a parent-status predicate keep the child
down. That inverts what a parent's status means in order to steer a sweep, and it stops working
silently the moment the predicate changes.
