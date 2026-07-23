import { logger } from "../middleware/logger.js";

type WakeupTriggerDetail = "manual" | "ping" | "callback" | "system";
type WakeupSource = "timer" | "assignment" | "on_demand" | "automation";

export interface IssueAssignmentWakeupDeps {
  wakeup: (
    agentId: string,
    opts: {
      source?: WakeupSource;
      triggerDetail?: WakeupTriggerDetail;
      reason?: string | null;
      payload?: Record<string, unknown> | null;
      requestedByActorType?: "user" | "agent" | "system";
      requestedByActorId?: string | null;
      contextSnapshot?: Record<string, unknown>;
    },
  ) => Promise<unknown>;
}

/**
 * Statuses that must never dispatch an assignment wake at the assignee.
 *
 * `backlog` is not yet promoted into the pipeline. `blocked` is a deliberate
 * "do not run this yet" set by a coordinator or the operator, and waking its
 * assignee is actively destructive: a no-skill agent (Worker/Architect) has no
 * way to decline the task, its run trivially exits 0, and the completion
 * handler then promotes the task off `blocked`. Because correcting the status
 * usually means re-setting the assignee too, the correction itself re-fires the
 * wake — a self-sustaining loop that flipped one blocked task four times in a
 * single day. The `blocked` guard in the run-completion handler
 * (`heartbeat.ts`, auto-done block) is the second half of this fix; this one
 * stops the wasted run and worktree allocation from happening at all.
 */
const NON_DISPATCHABLE_ISSUE_STATUSES = new Set(["backlog", "blocked"]);

export function isDispatchableIssueStatus(status: string): boolean {
  return !NON_DISPATCHABLE_ISSUE_STATUSES.has(status);
}

export function queueIssueAssignmentWakeup(input: {
  heartbeat: IssueAssignmentWakeupDeps;
  issue: { id: string; assigneeAgentId: string | null; status: string };
  reason: string;
  mutation: string;
  contextSource: string;
  requestedByActorType?: "user" | "agent" | "system";
  requestedByActorId?: string | null;
  rethrowOnError?: boolean;
  /**
   * When true, the wakeup's contextSnapshot carries `forceFreshSession: true`,
   * so the heartbeat runtime rotates the persisted `--resume` session instead
   * of replaying it. Use for cadences where the prior session is effectively
   * cold anyway (daily+ routines straddle Anthropic's cache TTL) — paying a
   * fresh session is cheaper than replaying stale cached context.
   */
  forceFreshSession?: boolean;
}) {
  if (!input.issue.assigneeAgentId || !isDispatchableIssueStatus(input.issue.status)) return;

  const contextSnapshot: Record<string, unknown> = {
    issueId: input.issue.id,
    source: input.contextSource,
  };
  if (input.forceFreshSession) contextSnapshot.forceFreshSession = true;

  return input.heartbeat
    .wakeup(input.issue.assigneeAgentId, {
      source: "assignment",
      triggerDetail: "system",
      reason: input.reason,
      payload: { issueId: input.issue.id, mutation: input.mutation },
      requestedByActorType: input.requestedByActorType,
      requestedByActorId: input.requestedByActorId ?? null,
      contextSnapshot,
    })
    .catch((err) => {
      logger.warn({ err, issueId: input.issue.id }, "failed to wake assignee on issue assignment");
      if (input.rethrowOnError) throw err;
      return null;
    });
}
