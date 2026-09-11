/**
 * Decide *whom* a completed subtask should wake, once `shouldWakeNextMover` has
 * decided that a wake is owed at all.
 *
 * Extracted from the heartbeat run executor for the same reason as its two
 * siblings (`stage-completion-wake`, `no-skill-completion-status`): the policy is
 * testable without a DB, a git remote or an adapter.
 *
 * Why this exists (AA-4004). The executor's `subtask.completed` arm resolved the
 * target as `parentIssue.assigneeAgentId` with no check on the parent at all —
 * not its status, not whether its assignee had anything left to do. The only gate
 * in front of it, `shouldWakeNextMover`, asks whether the *child* advanced.
 * `inReviewOnlyWhenOwnStageIsLive` does ask about the parent, but it filters the
 * chain-wake *candidate query*, so it never sees this direct `enqueueWakeup`.
 *
 * Measured on 2026-09-11: six of seven no-op Worker runs arrived as
 * `source: subtask.completed`, and three of those parents (AA-7213 twice,
 * AA-7201, AA-7424) were already `done` when the Worker was woken. The Worker
 * checked out the branch, found the commits already present, and exited — which
 * costs a run and changes nothing.
 */

export type SubtaskWakeTarget =
  /** Nothing downstream can advance; enqueue no wake. */
  | { kind: "none"; reason: string }
  /** The parent's own stage is live; its assignee is still the next mover. */
  | { kind: "parent-assignee" }
  /** The parent is parked with no live stage; the Coordinator is the next mover. */
  | { kind: "coordinator"; reason: string };

export function resolveSubtaskWakeTarget(input: {
  /** The parent task's status, or `null` when the parent row is missing. */
  parentStatus: string | null;
  /**
   * Whether the parent still has a child that is neither `done` nor `cancelled`,
   * *excluding* the subtask that just completed. "Is anyone still working?"
   */
  hasOtherOpenChild: boolean;
}): SubtaskWakeTarget {
  // A missing parent has no assignee to wake and no stage to advance. Falling
  // through would resolve `undefined?.assigneeAgentId` to null and enqueue
  // nothing anyway; saying so explicitly keeps the reason in the log.
  if (input.parentStatus === null) {
    return { kind: "none", reason: "parent row not found" };
  }

  // Terminal parent. Nothing downstream can advance, and the assignee named on a
  // `done` task is whoever last worked it — waking them buys a checkout, a git
  // read and an exit. This is the arm the 2026-09-11 evidence lands in.
  if (input.parentStatus === "done" || input.parentStatus === "cancelled") {
    return { kind: "none", reason: `parent is ${input.parentStatus}` };
  }

  // The parent is parked at the stage boundary and the child that just finished
  // was its last live stage. Its assignee has nothing left to do — that is the
  // precise shape `inReviewOnlyWhenOwnStageIsLive` suppresses on the chain-wake
  // path, applied here to the direct wake it cannot see. The Coordinator is the
  // real next mover: it creates the next stage, or merges.
  if (input.parentStatus === "in_review" && !input.hasOtherOpenChild) {
    return { kind: "coordinator", reason: "parent is in_review with no other open child" };
  }

  // Otherwise the parent assignee still owns a live stage. Unchanged behaviour,
  // and the case that keeps re-dispatch working for a no-skill Architect that
  // commits without landing: that task carries its own non-terminal verify
  // subtask, so it is not childless here.
  return { kind: "parent-assignee" };
}
