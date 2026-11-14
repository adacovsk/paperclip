import { and, eq, type SQL } from "drizzle-orm";
import type { PgUpdateSetSource } from "drizzle-orm/pg-core";
import type { Db } from "@paperclipai/db";
import { issues } from "@paperclipai/db";
import { conflict } from "../errors.js";
import { logger } from "../middleware/logger.js";
import { logActivity } from "./activity-log.js";

/**
 * The single write path for `issues.status`.
 *
 * Every update that can change an issue's status goes through `writeIssueStatus`,
 * so that every transition is checked by `assertTransition` and leaves an
 * activity row naming its from/to status, its actor and the call site that made
 * it. Before this existed, only the PATCH route logged a transition: the
 * service-level writes (run start, no-skill completion, checkout, release) moved
 * tasks without a trace, and the defects that came from those writes could not
 * be seen in the activity log at all.
 *
 * Writes that cannot touch `status` (execution-lock bookkeeping, a hold alone,
 * `updatedAt` bumps) do not need to come here.
 */

export const ISSUE_STATUS_CHANGED_ACTION = "issue.status_changed";

export type IssueStatusSource =
  | "issue_patch"
  | "comment_reopen"
  | "hold_comment"
  | "checkout"
  | "release"
  | "no_skill_run_start"
  | "no_skill_completion"
  | "run_escalation"
  | "unspecified";

export interface IssueStatusActor {
  actorType: "agent" | "user" | "system";
  actorId: string;
  agentId?: string | null;
  runId?: string | null;
}

export interface IssueWriteContext {
  actor: IssueStatusActor;
  /** Names the call site, so a transition in the log can be traced to the code that made it. */
  source: IssueStatusSource;
  /**
   * The caller writes its own activity row recording this transition (the PATCH
   * route's `issue.updated`, which carries `status` and `_previous.status`), so
   * no second row is written here. Only honoured for a status the caller asked
   * for: a status `update` derives on its own (a hold parking the task) is not
   * in the caller's row, and is logged here.
   */
  statusLoggedByCaller?: boolean;
}

export const UNSPECIFIED_ISSUE_WRITE_CONTEXT: IssueWriteContext = {
  actor: { actorType: "system", actorId: "issue_service" },
  source: "unspecified",
};

const ALL_ISSUE_STATUSES = ["backlog", "todo", "in_progress", "in_review", "blocked", "done", "cancelled"];

export function assertTransition(from: string, to: string) {
  if (from === to) return;
  if (!ALL_ISSUE_STATUSES.includes(to)) {
    throw conflict(`Unknown issue status: ${to}`);
  }
}

type IssueRow = typeof issues.$inferSelect;
// `status` is a plain value, never a SQL expression: the transition check and
// the from/to log both need to know the target before the write.
type IssuePatch = PgUpdateSetSource<typeof issues> & { status?: string };
// Both the top-level db and a transaction handle; drizzle's types for the two differ.
type DbOrTx = Pick<Db, "select" | "update" | "insert" | "transaction">;

export interface WriteIssueStatusInput {
  issueId: string;
  /** Every column written by this statement, status included when it is being set. */
  set: IssuePatch;
  /**
   * Extra guard ANDed with `id = issueId`, exactly as the call site wrote it
   * (e.g. checkout's expected-status and lock conditions). A guard that fails
   * returns null, as `.returning()` did.
   */
  where?: SQL;
  context: IssueWriteContext;
  /** Skip the activity row even if status changed. Used by `update` for `statusLoggedByCaller`. */
  skipActivity?: boolean;
}

export interface WriteIssueStatusResult {
  row: IssueRow;
  previousStatus: string;
}

/**
 * Performs one `UPDATE issues ... RETURNING *` and logs the status transition it made.
 *
 * The previous status is read with `SELECT ... FOR UPDATE` in the same
 * transaction as the update. The row lock is the one the UPDATE would take
 * anyway, taken one statement earlier, so the reading cannot go stale between
 * the two and the guard in `where` is still what decides whether the write
 * wins. The pre-read is for logging only; it never short-circuits the update.
 */
export async function writeIssueStatus(
  dbOrTx: DbOrTx,
  input: WriteIssueStatusInput,
): Promise<WriteIssueStatusResult | null> {
  const { issueId, set, where, context } = input;
  const condition = where ? and(eq(issues.id, issueId), where) : eq(issues.id, issueId);
  const writesStatus = set.status !== undefined;

  if (!writesStatus) {
    const row = await dbOrTx
      .update(issues)
      .set(set)
      .where(condition)
      .returning()
      .then((rows) => rows[0] ?? null);
    return row ? { row, previousStatus: row.status } : null;
  }

  // `transaction` on a transaction handle opens a savepoint, so this works for
  // callers that are already inside one.
  return dbOrTx.transaction(async (tx) => {
    const previous = await tx
      .select({ status: issues.status })
      .from(issues)
      .where(eq(issues.id, issueId))
      .for("update")
      .then((rows) => rows[0] ?? null);
    if (!previous) return null;

    assertTransition(previous.status, set.status!);

    const row = await tx
      .update(issues)
      .set(set)
      .where(condition)
      .returning()
      .then((rows) => rows[0] ?? null);
    if (!row) return null;

    if (row.status !== previous.status && !input.skipActivity) {
      // In its own savepoint: a log row that cannot be written (a run id with no
      // heartbeat_runs row trips the foreign key) must not undo the transition,
      // which was never conditional on being logged.
      await tx.transaction((logTx) => logActivity(logTx as unknown as Db, {
        actorType: context.actor.actorType,
        actorId: context.actor.actorId,
        agentId: context.actor.agentId ?? null,
        runId: context.actor.runId ?? null,
        action: ISSUE_STATUS_CHANGED_ACTION,
        entityType: "issue",
        entityId: row.id,
        details: {
          status: row.status,
          _previous: { status: previous.status },
          source: context.source,
          identifier: row.identifier,
        },
      })).catch((err: unknown) => {
        logger.warn(
          { err, issueId: row.id, from: previous.status, to: row.status, source: context.source },
          "failed to log issue status transition",
        );
      });
    }

    return { row, previousStatus: previous.status };
  });
}
