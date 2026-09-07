import { isDispatchableIssueStatus } from "./issue-assignment-wakeup.js";

/**
 * A wake fired at a paused agent is discarded — `enqueueWakeup` throws
 * `Agent is not invokable in its current state` and nothing persists the
 * request — and resuming the agent replays nothing. The assignment is stranded
 * permanently: the task keeps its assignee and its status, carries
 * `activeRun = null` / `executionRunId = null`, and no sweep distinguishes it
 * from a task that is legitimately queued.
 *
 * Observed on AA-5029, assigned 23:54:06Z to a Reviewer that paused at 00:07:59.
 * The Reviewer was resumed and then completed three reviews filed *after* it —
 * so it was neither paused nor saturated when it skipped this one. Nothing
 * distinguished AA-5029 except when its wake was issued.
 *
 * The fix is reconciliation, not event replay. Re-deriving the set from issue
 * state on resume is idempotent, needs nothing stored at pause time, and also
 * recovers assignments stranded by causes other than a pause (a wake lost to a
 * restart, a crashed dispatcher). Replaying stored wake records would recover
 * only the drops we predicted.
 */
export function selectAssignmentsToReplayOnResume<
  T extends {
    id: string;
    status: string;
    assigneeAgentId: string | null;
    activeRunId?: string | null;
    executionRunId: string | null;
  },
>(issues: readonly T[], agentId: string, limit = 25): T[] {
  return issues
    .filter((issue) => {
      // Assigned to the agent being resumed. A wake at anyone else is not this
      // agent's to re-fire.
      if (issue.assigneeAgentId !== agentId) return false;

      // Same gate the live assignment wake uses. `backlog` and `blocked` must
      // never dispatch — re-firing one on resume would reintroduce exactly the
      // self-sustaining loop `isDispatchableIssueStatus` exists to stop.
      if (!isDispatchableIssueStatus(issue.status)) return false;

      // Never re-fire onto a task that already has a run. A live run means the
      // agent picked the task up after resuming and a second wake would race it;
      // a stale `executionRunId` with no active run is a *different* defect with
      // its own recovery path, and firing a wake at it here would mint a run
      // that immediately deadlocks on the lock it cannot clear.
      if (issue.activeRunId) return false;
      if (issue.executionRunId) return false;

      return true;
    })
    .slice(0, limit);
}
