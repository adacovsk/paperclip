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
  /**
   * Whether the task branch's head on origin moved during the run, from
   * `branchAdvancedDuringRun`. `null` when either reading failed, so the run's
   * effect on the branch is unknown.
   */
  branchAdvanced: boolean | null;
  /**
   * Whether the run's own report blocked the task (the Architect's escalation
   * marker). That is a status change the server wrote after `nextStatus` was
   * decided, so it is an advance the next mover has to read.
   */
  escalated: boolean;
}): boolean {
  // A status transition is the advance. The next mover has something new to read
  // precisely because the task no longer says what it said before the run.
  if (input.nextStatus !== null || input.escalated) return true;

  // No transition, and the task was already parked at the stage boundary. That
  // covers two exits the status cannot tell apart: a re-dispatched stage that
  // landed (an Architect re-verify that pushed and opened the PR), and one that
  // only started or re-armed something and will be woken again when it finishes
  // (a verify offloaded to the cloud lane, or re-launched because the base
  // moved). Only the first gives the next mover anything to read. The branch
  // head on origin separates them: landing pushes it, waiting does not.
  //
  // Waking on both sent `subtask_completed` up to the parent on every
  // still-in-flight verify exit — twice per Verify within an hour while the
  // Verify itself never left `in_review` — and each one reached the Worker for a
  // run that found its commits present and exited.
  //
  // An unreadable branch keeps the wake. A spurious wake costs one run; a missed
  // one leaves a landed stage waiting for the Coordinator's next scheduled sweep.
  if (input.currentStatus === "in_review") return input.branchAdvanced !== false;

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

/**
 * The head of `refs/heads/<branch>` in `git ls-remote --heads origin <branch>`
 * output, or `null` when the branch is not listed.
 *
 * Matched on the full ref name: ls-remote treats its pattern as a suffix match,
 * so `task/X-1` also lists a `refs/heads/foo/task/X-1`.
 */
export function parseLsRemoteHead(stdout: string, branch: string): string | null {
  const wanted = `refs/heads/${branch}`;
  for (const line of stdout.split("\n")) {
    const [sha, ref] = line.trim().split(/\s+/);
    if (ref === wanted && sha) return sha;
  }
  return null;
}

/**
 * Did the run move the task branch on origin?
 *
 * Each reading is `{ sha }` (`sha: null` when the branch is absent on origin)
 * or `null` when it could not be read. An unreadable side answers `null`
 * rather than guessing: "unknown" and "unchanged" call for different wakes.
 */
export function branchAdvancedDuringRun(
  before: { sha: string | null } | null,
  after: { sha: string | null } | null,
): boolean | null {
  if (before === null || after === null) return null;
  return before.sha !== after.sha;
}
