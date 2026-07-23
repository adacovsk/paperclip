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

  // Already where it needs to be.
  if (input.currentStatus === "in_review") return null;

  // `blocked` is a deliberate coordinator/operator decision that the task must
  // not advance (typically an unmerged cross-task dependency). A no-skill run
  // exits 0 whether or not it did anything, so arriving here is no evidence the
  // block cleared. Promoting it would silently discard a human decision and
  // re-enter the task into the pipeline against a base commit that lacks its
  // dependency. Only whoever set `blocked` may clear it.
  if (input.currentStatus === "blocked") return null;

  return "in_review";
}
