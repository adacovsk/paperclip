/**
 * Surface an Architect run's final message on its task.
 *
 * The Architect carries no `paperclip` skill, so it has no sanctioned way to
 * comment or change status. When it decides a task needs the operator — a red
 * build outside its scope, a base it cannot rebase onto, the fix-cycle cap — that
 * decision lives only in the run's `resultJson.result`. Left there, the task
 * stays at `in_review` with no comment and no status change, which reads exactly
 * like a verify still in flight: verify tasks sat that way for up to two days,
 * and a pipeline-health sweep misdiagnosed them as a lost wake.
 *
 * Extracted from the heartbeat run executor so the policy is testable without a
 * DB or an adapter — the same split as `resolveNoSkillCompletionStatus`.
 */

/**
 * The line an Architect ends its final message with to hand a task to the
 * operator. Must start a line and be followed by a one-line reason.
 *
 * Why an explicit marker rather than inferring escalation from run state: an
 * Architect run that landed a PR, one that launched a detached or cloud verify,
 * one that timed out waiting on a build and one that gave up all exit 0 and leave
 * the task at `in_review`. Neither the sentinel files nor the detached-run record
 * separate them reliably — a queued build has no detached run yet, and a landed
 * task can still carry a stale sentinel — and blocking a task mid-verify or
 * after landing is worse than not blocking an escalation. Only the agent knows
 * which one it did, so it says so.
 *
 * Why this form: upper-case, hyphenated and colon-terminated, it is not
 * Markdown syntax the model reformats, and does not occur in ordinary prose.
 * Line-anchored, so a message that merely mentions the token mid-sentence does
 * not block its task.
 */
export const ARCHITECT_ESCALATION_MARKER = "PAPERCLIP-ESCALATE:";

/** Comments longer than this keep their head and tail, which is where an
 * Architect puts its outcome and its escalation line respectively. */
export const RUN_REPORT_MAX_CHARS = 8000;
const RUN_REPORT_TAIL_CHARS = 2000;

const ESCALATION_LINE = new RegExp(
  `^[ \\t]*${ARCHITECT_ESCALATION_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[ \\t]*(\\S.*)$`,
  "m",
);

/** The one-line reason after the marker, or null when the text does not escalate. */
export function findEscalationReason(text: string): string | null {
  const match = ESCALATION_LINE.exec(text);
  return match ? match[1].trim() : null;
}

/** The run's final message: the adapter's structured result, else its summary. */
export function extractRunResultText(input: {
  resultJson?: Record<string, unknown> | null;
  summary?: string | null;
}): string {
  const result = input.resultJson?.result;
  if (typeof result === "string" && result.trim()) return result.trim();
  return typeof input.summary === "string" ? input.summary.trim() : "";
}

export function truncateRunReport(text: string, max = RUN_REPORT_MAX_CHARS): string {
  if (text.length <= max) return text;
  const tail = Math.min(RUN_REPORT_TAIL_CHARS, Math.floor(max / 4));
  const head = max - tail;
  const omitted = text.length - head - tail;
  return `${text.slice(0, head)}\n\n… [${omitted} characters omitted] …\n\n${text.slice(text.length - tail)}`;
}

/** Statuses a task is in while the pipeline still owns it, so an escalation may
 * move it to `blocked`. Anything else is a decision someone already made. */
const BLOCKABLE_STATUSES = new Set(["todo", "in_progress", "in_review"]);

export function planNoSkillRunReport(input: {
  /** The agent's role (`agents.role`). */
  role: string | null | undefined;
  /** The task's status when the run finished. */
  currentStatus: string;
  /** What `resolveNoSkillCompletionStatus` decided to write, or null. */
  nextStatus: "done" | "in_review" | null;
  /** The run's final message, see `extractRunResultText`. */
  resultText: string;
}): { comment: string | null; block: boolean; escalationReason: string | null } {
  const none = { comment: null, block: false, escalationReason: null };

  // Architect only. A Worker's exit is a normal intermediate stage — it commits
  // and the Reviewer picks it up — and its final message is a work log the next
  // stage reads from the branch, so posting it would add a comment to every task
  // the pipeline touches. The Architect is the one no-skill role whose run can
  // end in a decision only a human can act on.
  if (input.role !== "architect") return none;

  // Merged is the one outcome that needs no explanation on the task. Promotion
  // to `in_review` does not count as advancing here: that is the server's
  // bookkeeping for an exit that left the branch unmerged, and an escalation
  // from `in_progress` is just as invisible after it as before.
  if (input.nextStatus === "done") return none;

  const text = input.resultText.trim();
  if (!text) return none;

  const escalationReason = findEscalationReason(text);
  return {
    comment: truncateRunReport(text),
    block: escalationReason !== null && BLOCKABLE_STATUSES.has(input.currentStatus),
    escalationReason,
  };
}
