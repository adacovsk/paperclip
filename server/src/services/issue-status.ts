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

export const ISSUE_STATUS_TRANSITION_FLAGGED_ACTION = "issue.status_transition_flagged";

/**
 * Who may make a status move: `allow` anyone; `operator` only a user actor
 * (the operator's own sessions), never an agent or the server; `reject` nobody.
 */
export type TransitionRule = "allow" | "operator" | "reject";

/**
 * The status machine: every from -> to pair, ruled.
 *
 * Ruled pair by pair against eight months of logged transitions (46k rows).
 * The table this replaced (SPEC §8.2) disallowed 25 of the 40 pairs actually
 * in use -- 48% of all traffic, including the Architect's escalation
 * (`in_review -> blocked`) and every hold the Dispatcher places -- so it was
 * never enforceable. Every pair here is listed, `allow` included, so a pair
 * nobody ruled on is a missing key the test catches, not a silent default.
 *
 * Two rules shape the rejects:
 * - `backlog` is reachable only from work that has not started (`todo`,
 *   `blocked`). Work that ran is finished, cancelled, or held, not re-planned.
 * - `done` and `cancelled` are left only through `todo` (a reopen), plus
 *   `in_review`: for the operator from `cancelled`, for anyone from `done`.
 *   `cancelled -> done` was a race: a run already working on a task finished
 *   seconds after the cancel and overwrote it. `-> in_progress` from either
 *   would hold the status with no run behind it.
 *
 * `done -> in_review` is open to agents for the Coordinator's PR-evidence audit,
 * which reopens a task closed with no PR and no commit on main for a fresh
 * verify. It cannot go through `todo` instead: that wakes a Worker to redo work
 * that exists and only failed to land.
 */
export const ISSUE_STATUS_TRANSITIONS: Readonly<Record<string, Readonly<Record<string, TransitionRule>>>> = {
  backlog: {
    todo: "allow", in_progress: "allow", in_review: "operator", blocked: "allow", done: "allow", cancelled: "allow",
  },
  todo: {
    backlog: "allow", in_progress: "allow", in_review: "allow", blocked: "allow", done: "allow", cancelled: "allow",
  },
  in_progress: {
    backlog: "reject", todo: "allow", in_review: "allow", blocked: "allow", done: "allow", cancelled: "allow",
  },
  in_review: {
    backlog: "reject", todo: "allow", in_progress: "allow", blocked: "allow", done: "allow", cancelled: "allow",
  },
  blocked: {
    backlog: "allow", todo: "allow", in_progress: "allow", in_review: "allow", done: "allow", cancelled: "allow",
  },
  done: {
    backlog: "reject", todo: "allow", in_progress: "reject", in_review: "allow", blocked: "reject", cancelled: "reject",
  },
  cancelled: {
    backlog: "reject", todo: "allow", in_progress: "reject", in_review: "operator", blocked: "reject", done: "reject",
  },
};

/** Titles the pipeline gives its stage subtasks; many predate `dedupeKey`. */
const STAGE_TITLE_PREFIXES = ["Review:", "Verify:", "ci-fix:", "Rebase "];
const STAGE_DEDUPE_KEYS = ["review", "verify", "rebase", "ci-fix"];
/** The two writes that put a run behind `in_progress`. */
const RUN_ENTRY_SOURCES: readonly IssueStatusSource[] = ["checkout", "no_skill_run_start"];

export type TransitionFlagKind =
  /** The table says only the operator may make this move. */
  | "operator_only"
  /** The table says nobody makes this move. */
  | "rejected"
  /** `todo -> in_review` on a task that is not a stage subtask: it skipped its Worker. */
  | "review_without_work"
  /** `blocked -> in_review` written by the server at a no-skill run's end: a held task overwritten. */
  | "completion_over_hold"
  /** Into `in_progress` other than by checkout or a run start: no run holds the task. */
  | "in_progress_without_run";

export interface TransitionFlag {
  kind: TransitionFlagKind;
  reason: string;
}

export interface CheckTransitionInput {
  from: string;
  to: string;
  context: IssueWriteContext;
  issue: { title: string; dedupeKey: string | null };
}

function isStageSubtask(issue: CheckTransitionInput["issue"]): boolean {
  return (
    (issue.dedupeKey !== null && STAGE_DEDUPE_KEYS.includes(issue.dedupeKey)) ||
    STAGE_TITLE_PREFIXES.some((prefix) => issue.title.startsWith(prefix))
  );
}

/**
 * What is wrong with one transition, if anything: the table's ruling for the
 * pair, plus three checks a from/to table cannot express. Pure.
 *
 * `writeIssueStatus` records every flag as an activity row. Which flags also
 * stop the write is `refusedFlags`'s decision, not this function's.
 */
export function checkTransition({ from, to, context, issue }: CheckTransitionInput): TransitionFlag[] {
  if (from === to) return [];
  const flags: TransitionFlag[] = [];
  const rule = ISSUE_STATUS_TRANSITIONS[from]?.[to];
  const byOperator = context.actor.actorType === "user";

  if (rule === "reject") {
    flags.push({ kind: "rejected", reason: `${from} -> ${to} is not a permitted move` });
  } else if (rule === "operator" && !byOperator) {
    flags.push({ kind: "operator_only", reason: `${from} -> ${to} is the operator's move, made by ${context.actor.actorType}` });
  }

  if (from === "todo" && to === "in_review" && !isStageSubtask(issue)) {
    flags.push({ kind: "review_without_work", reason: "reached review from todo without a Worker stage" });
  }
  if (from === "blocked" && to === "in_review" && context.source === "no_skill_completion") {
    flags.push({ kind: "completion_over_hold", reason: "a run's completion moved a held task to review" });
  }
  if (to === "in_progress" && !RUN_ENTRY_SOURCES.includes(context.source)) {
    flags.push({ kind: "in_progress_without_run", reason: `entered in_progress through ${context.source}, not a checkout` });
  }
  return flags;
}

/** The flag kinds that stop a write. The other three are reported and let through. */
const REFUSED_FLAG_KINDS: readonly TransitionFlagKind[] = ["operator_only", "rejected"];

/**
 * Writes the server makes on its own at a run's start or end. A refusal there
 * is skipped like a failed guard (the task is left as it is), never thrown: the
 * throw would surface inside the heartbeat, which has no caller to answer 409 to.
 */
const SKIP_ON_REFUSAL_SOURCES: readonly IssueStatusSource[] = [
  "no_skill_run_start",
  "no_skill_completion",
  "run_escalation",
];

/**
 * The flags that refuse this write. None for a user actor: the operator may
 * make any move, a `reject` cell included, and it is still recorded as flagged.
 */
export function refusedFlags(flags: TransitionFlag[], context: IssueWriteContext): TransitionFlag[] {
  if (context.actor.actorType === "user") return [];
  return flags.filter((flag) => REFUSED_FLAG_KINDS.includes(flag.kind));
}

/** Thrown inside the write's transaction to roll the UPDATE back; never leaves `writeIssueStatus`. */
class TransitionRefused extends Error {
  constructor(
    readonly from: string,
    readonly to: string,
    readonly identifier: string | null,
    readonly flags: TransitionFlag[],
    readonly refused: TransitionFlag[],
  ) {
    super("issue status transition refused");
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
  /**
   * Where a refused move's flag row is written. A caller that passes its own
   * transaction as `dbOrTx` passes the top-level db here: the 409 rolls that
   * transaction back, and a row written inside it would go with it.
   */
  flagDb?: DbOrTx;
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
 * wins. The pre-read never short-circuits the update.
 *
 * A move the table refuses (`refusedFlags`) is rolled back and answered with a
 * 409, or with null for the server's own run-start and run-end writes. It is
 * refused only after the guarded UPDATE matched, never at the pre-read: a write
 * whose `where` guard would skip it returns null, and does not throw on a move
 * it was never going to make. The flag row is written either way.
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
  const written = await dbOrTx.transaction(async (tx) => {
    const previous = await tx
      .select({ status: issues.status, title: issues.title, dedupeKey: issues.dedupeKey })
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

    if (row.status === previous.status) return { row, previousStatus: previous.status };
    const transition = { issueId: row.id, from: previous.status, to: row.status, source: context.source };

    const flags = checkTransition({ from: previous.status, to: row.status, context, issue: previous });
    const refused = refusedFlags(flags, context);
    if (refused.length > 0) {
      throw new TransitionRefused(previous.status, row.status, row.identifier, flags, refused);
    }

    if (!input.skipActivity) {
      await logInSavepoint(tx, {
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
      }, transition, "failed to log issue status transition");
    }

    if (flags.length > 0) {
      logger.warn(
        { ...transition, actor: context.actor, flags },
        `issue status transition flagged: ${flags.map((flag) => flag.kind).join(", ")}`,
      );
      await logInSavepoint(
        tx,
        flaggedActivity(row.id, row.identifier, previous.status, row.status, context, flags, false),
        transition,
        "failed to log flagged issue status transition",
      );
    }

    return { row, previousStatus: previous.status };
  }).catch((err: unknown) => {
    if (err instanceof TransitionRefused) return err;
    throw err;
  });
  if (!(written instanceof TransitionRefused)) return written;

  const { from, to, identifier, flags, refused } = written;
  const transition = { issueId, from, to, source: context.source };
  const skipped = SKIP_ON_REFUSAL_SOURCES.includes(context.source);
  logger.warn(
    { ...transition, actor: context.actor, flags, skipped },
    `issue status transition refused: ${refused.map((flag) => flag.kind).join(", ")}`,
  );
  await logActivity(
    (input.flagDb ?? dbOrTx) as unknown as Db,
    flaggedActivity(issueId, identifier, from, to, context, flags, true),
  ).catch((err: unknown) => {
    logger.warn({ err, ...transition }, "failed to log refused issue status transition");
  });
  if (skipped) return null;
  throw conflict(
    `Status move refused: ${refused.map((flag) => flag.reason).join("; ")}. ` +
      "Nothing was written. Do not retry this move as it is: re-read the task and make a permitted move.",
    { from, to, flags: refused.map((flag) => flag.kind), reasons: refused.map((flag) => flag.reason) },
  );
}

/**
 * The activity row for a flagged move. Written as the system, not as the actor:
 * the actor did not flag anything, and an agent-attributed row would count
 * toward its participation and cost. `status` is the status asked for; when
 * `refused` is true the task did not reach it.
 */
function flaggedActivity(
  issueId: string,
  identifier: string | null,
  from: string,
  to: string,
  context: IssueWriteContext,
  flags: TransitionFlag[],
  refused: boolean,
): Parameters<typeof logActivity>[1] {
  return {
    actorType: "system",
    actorId: "issue_status_table",
    agentId: null,
    runId: null,
    action: ISSUE_STATUS_TRANSITION_FLAGGED_ACTION,
    entityType: "issue",
    entityId: issueId,
    details: {
      status: to,
      _previous: { status: from },
      source: context.source,
      identifier,
      flags: flags.map((flag) => flag.kind),
      reasons: flags.map((flag) => flag.reason),
      actor: context.actor,
      refused,
    },
  };
}

/**
 * Write one activity row in its own savepoint. A log row that cannot be written
 * (a run id with no heartbeat_runs row trips the foreign key) must not undo the
 * transition, which was never conditional on being logged.
 */
async function logInSavepoint(
  tx: Parameters<Parameters<DbOrTx["transaction"]>[0]>[0],
  activity: Parameters<typeof logActivity>[1],
  transition: Record<string, unknown>,
  failure: string,
): Promise<void> {
  await tx
    .transaction((logTx) => logActivity(logTx as unknown as Db, activity))
    .catch((err: unknown) => {
      logger.warn({ err, ...transition }, failure);
    });
}
