/**
 * Decide whether a run by an agent that lacks the `paperclip` skill (Worker /
 * Architect) should wake the next mover when it exits.
 *
 * Extracted from the heartbeat run executor so the policy is testable without a
 * DB, a git remote, or an adapter — the same split as
 * `resolveNoSkillCompletionStatus`, whose output is this function's input.
 */
export function shouldWakeNextMover(input: {
  /** The task's status at the moment the run finished. */
  currentStatus: string;
  /**
   * What `resolveNoSkillCompletionStatus` decided to write, or `null` when it
   * declined to promote. This is the whole record of what the run changed: a
   * no-skill agent cannot PATCH its own status, so if the server wrote nothing,
   * nothing about the task moved.
   */
  nextStatus: "done" | "in_review" | null;
}): boolean {
  // A status transition is the advance. The next mover has something new to read
  // precisely because the task no longer says what it said before the run.
  if (input.nextStatus !== null) return true;

  // No transition, but the task was already parked at the stage boundary. This is
  // the normal shape of a verify or a re-dispatched stage that finishes without
  // changing status, and it is a real completion the next mover owes an action
  // on — the work landed on the branch even though the status did not move. Wake.
  if (input.currentStatus === "in_review") return true;

  // No transition, and the status is outside the promotion allowlist: `blocked`,
  // `backlog`, `cancelled` or `done`. The executor has *already established* that
  // nothing advanced — it logs "a no-skill exit 0 is not evidence it should
  // advance" on this exact branch — and each of these statuses is someone's
  // deliberate decision that the task is not moving. There is no next mover to
  // wake, because there is no next move.
  //
  // The wake used to fire here anyway. For a top-level task the target resolves
  // by `role = 'coordinator'`, so every such exit woke the Coordinator into a
  // full sweep to re-read a task nobody could act on: 16 Coordinator runs between
  // 01:27Z and 01:53Z on 2026-08-07, each `source: subtask.completed` with a
  // different `completedSubtaskId`, an inter-fire gap of 50-180s. The routine
  // trigger fired once that day; the storm was entirely callback-driven.
  return false;
}
