/**
 * Decide what status a task should carry after a run by an agent that lacks the
 * `paperclip` skill (Worker / Architect). Those agents cannot PATCH their own
 * status, so the server reflects the run outcome into the task for them.
 *
 * Extracted from the heartbeat run executor so the policy is testable without a
 * DB, a git remote, or an adapter.
 */
export function resolveNoSkillCompletionStatus(input: {
  /** The task's status at the moment the run finished. */
  currentStatus: string;
  /** True only on a positive `git ls-remote` confirmation that the task branch landed. */
  branchOnOrigin: boolean;
}): "done" | "in_review" | null {
  // Layer-2 anti-masquerade invariant: a no-skill task may auto-complete only
  // when its branch is confirmed on origin.
  if (input.branchOnOrigin) return "done";

  // Promotion is an ALLOWLIST, not a denylist. A no-skill run exits 0 whether or
  // not it did any work, so reaching this point is no evidence about the task —
  // only the task's own status says whether a promotion is wanted. Just two
  // statuses describe a task that was dispatched and is still in flight, and
  // therefore legitimately owes an `in_review`.
  //
  // Every other status is someone's deliberate decision that this task is not
  // advancing, and promoting it silently discards that decision:
  //   - `blocked`   — coordinator/operator held it (usually an unmerged
  //                   cross-task dependency); promoting re-enters it into the
  //                   pipeline against a base commit that lacks that dependency.
  //   - `backlog`   — reverted out of the pipeline, typically mid-run, for
  //                   exactly that reason.
  //   - `cancelled` — abandoned; resurrecting it is strictly wrong.
  //   - `done`      — already terminal.
  //   - `in_review` — already where it needs to be.
  //
  // This was previously written as a denylist that named only `blocked`, so
  // every other non-active status still fell through to `in_review`. That let a
  // task reverted to `backlog` mid-run get flipped back into the pipeline by the
  // very run the revert was meant to abandon, four times over. Keep this an
  // allowlist: a status added to the system later must opt IN to promotion
  // rather than silently inherit it.
  if (input.currentStatus === "todo" || input.currentStatus === "in_progress") return "in_review";

  return null;
}
