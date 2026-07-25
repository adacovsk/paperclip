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

/**
 * True when the agent being woken is the same agent that requested the mutation.
 *
 * An agent that assigns a task to *itself* needs no wake: it is already running,
 * and it sees its own mutation without one. Waking it instead mints a brand-new
 * run per mutation — so a sweep procedure that reassigns several tasks to itself
 * to "revive" them mints one run each, and each of those runs re-runs the sweep.
 * That is a self-sustaining loop, not a slow drip: it fired a once-daily
 * Facilitator routine 9 times in 100 minutes, with three runs created inside a
 * single 6-second window.
 *
 * Same shape as the `blocked` guard above — the wake that "corrects" state is
 * itself what re-fires the correction.
 *
 * Keyed on the *actor*, not the assignee: an operator or a routine assigning an
 * idle agent its own task must still wake it, or nothing would ever dispatch.
 * Callers that build wakeup payloads inline must consult this too — the check
 * lives here so there is one copy of the rule rather than one per call site.
 */
export function isSelfAssignmentWake(
  assigneeAgentId: string | null,
  actor: { requestedByActorType?: "user" | "agent" | "system"; requestedByActorId?: string | null },
): boolean {
  return (
    actor.requestedByActorType === "agent"
    && !!actor.requestedByActorId
    && actor.requestedByActorId === assigneeAgentId
  );
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
  if (isSelfAssignmentWake(input.issue.assigneeAgentId, input)) return;

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
