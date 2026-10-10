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
   * Whether the parent still has a live child, *excluding* the subtask that just
   * completed. "Is anyone still working?" Compute it with `summarizeOpenChildren`,
   * which also decides what "live" means.
   */
  hasOtherOpenChild: boolean;
  /**
   * Whether one of those other live children is assigned to the parent's own
   * assignee. Only meaningful when `hasOtherOpenChild` is true.
   */
  assigneeOwnsOtherOpenChild: boolean;
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

  // Parked, and still waiting — but on a stage someone else owns (a Reviewer
  // finished while the Architect's Verify is still open). The parent's assignee
  // has nothing to do until that stage lands, and that stage's own completion is
  // the wake that moves the parent. This is the first arm of
  // `inReviewOnlyWhenOwnStageIsLive`, which the chain-wake query already applies;
  // without it here, every Reviewer completion under a verifying parent woke the
  // Worker for a run that found its commits present and exited.
  if (input.parentStatus === "in_review" && !input.assigneeOwnsOtherOpenChild) {
    return { kind: "none", reason: "parent is in_review waiting on a stage another agent owns" };
  }

  // Otherwise the parent assignee still owns a live stage. Unchanged behaviour,
  // and the case that keeps re-dispatch working for a no-skill Architect that
  // commits without landing: that task carries its own non-terminal verify
  // subtask, so it is not childless here.
  return { kind: "parent-assignee" };
}

/**
 * Whether a comment on an issue should wake its assignee.
 *
 * Same predicate as the subtask arm above, for the comment path: an `in_review`
 * issue whose assignee owns none of its open children is parked on a stage that
 * agent cannot move. Comments on such a parent come from the agents working its
 * stages and from the Coordinator recording progress, so waking the assignee on
 * each one bought a checkout, a git read and an exit. A Worker cannot even read
 * the comment — it sees only the task prompt. `@`-mentions are resolved
 * separately and still wake whoever they name, and a comment that reopens the
 * issue is decided before this is consulted.
 */
export function commentWakesAssignee(input: {
  status: string;
  assigneeOwnsOpenChild: boolean;
}): boolean {
  return !(input.status === "in_review" && !input.assigneeOwnsOpenChild);
}

/** One sibling or child row, as the wake gates need to read it. */
export interface OpenChild {
  assigneeAgentId: string | null;
  status: string;
}

/**
 * Reduce a parent's non-terminal children to the two facts the wake gates ask:
 * is anyone still working under this parent, and is that someone the parent's
 * own assignee?
 *
 * A child owned by the parent's assignee and parked `in_review` counts as
 * neither. It is the same shape as the parent itself: that agent's stage on it
 * is finished, and the next move belongs to whoever owns the next stage or the
 * merge, never to its owner. Counting it as "the assignee owns another open
 * child" sent every stage completion under such a parent to the Worker — a
 * follow-up or rebase sibling sitting parked beside a Verify was enough —
 * where it re-read a branch whose work was already committed and exited.
 * Counting it as "someone is still working" would suppress the Coordinator
 * wake the parked pair is waiting on.
 *
 * `in_review` on a child owned by *another* agent is left counted: an
 * Architect's Verify sits `in_review` while its build is in flight, and its
 * own completion is the wake that moves the parent.
 */
export function summarizeOpenChildren(
  children: readonly OpenChild[],
  parentAssigneeId: string | null,
): { hasOtherOpenChild: boolean; assigneeOwnsOtherOpenChild: boolean } {
  const live = children.filter(
    (child) =>
      child.status !== "done" &&
      child.status !== "cancelled" &&
      !(parentAssigneeId !== null && child.assigneeAgentId === parentAssigneeId && child.status === "in_review"),
  );
  return {
    hasOtherOpenChild: live.length > 0,
    assigneeOwnsOtherOpenChild:
      parentAssigneeId !== null && live.some((child) => child.assigneeAgentId === parentAssigneeId),
  };
}
