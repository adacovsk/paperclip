import { and, desc, eq, inArray, or, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { issueComments, issues } from "@paperclipai/db";
import {
  holdSurvivesStatus,
  isUuidLike,
  parseHoldLine,
  type IssueHold,
  type IssueHoldBlocker,
  type IssueHoldInput,
  type IssueHoldKind,
} from "@paperclipai/shared";
import { unprocessable } from "../errors.js";

/**
 * Marks a row whose hold the migration could not read in SQL. `backfillHolds`
 * replaces every one at the next boot, so the value never reaches a caller.
 */
export const HOLD_PENDING_BACKFILL = "pending_backfill";

export interface HoldActor {
  agentId?: string | null;
  userId?: string | null;
}

/** Where a hold would stand once a patch is applied. */
export interface HoldPlacement {
  status: string;
  assigned: boolean;
}

/**
 * The status and assignee a task ends up with when `patch` carries a hold. A
 * hold written onto a task whose status it cannot stand under parks the task as
 * `blocked`; an explicit status in the patch is taken as given.
 */
export function holdPlacement(
  kind: IssueHoldKind,
  existing: { status: string; assigneeAgentId: string | null; assigneeUserId: string | null },
  patch: { status?: string; assigneeAgentId?: string | null; assigneeUserId?: string | null },
): HoldPlacement {
  const status = patch.status ?? (holdSurvivesStatus(kind, existing.status) ? existing.status : "blocked");
  const agent = patch.assigneeAgentId !== undefined ? patch.assigneeAgentId : existing.assigneeAgentId;
  const user = patch.assigneeUserId !== undefined ? patch.assigneeUserId : existing.assigneeUserId;
  return { status, assigned: Boolean(agent || user) };
}

export function issueHoldService(db: Db) {
  async function resolveBlockers(refs: string[]) {
    const wanted = [...new Set(refs.map((ref) => ref.trim()).filter(Boolean))];
    if (wanted.length === 0) return { blockers: [] as IssueHoldBlocker[], missing: [] as string[] };
    const ids = wanted.filter((ref) => isUuidLike(ref));
    const identifiers = wanted.filter((ref) => !isUuidLike(ref)).map((ref) => ref.toUpperCase());
    const rows = await db
      .select({ id: issues.id, identifier: issues.identifier })
      .from(issues)
      .where(
        or(
          ids.length > 0 ? inArray(issues.id, ids) : undefined,
          identifiers.length > 0 ? inArray(issues.identifier, identifiers) : undefined,
        ),
      );
    const blockers: IssueHoldBlocker[] = [];
    const missing: string[] = [];
    for (const ref of wanted) {
      const row = rows.find((candidate) =>
        isUuidLike(ref) ? candidate.id === ref : candidate.identifier === ref.toUpperCase(),
      );
      if (!row?.identifier) missing.push(ref);
      else if (!blockers.some((blocker) => blocker.id === row.id)) {
        blockers.push({ id: row.id, identifier: row.identifier });
      }
    }
    return { blockers, missing };
  }

  function stamped(
    kind: IssueHoldKind,
    blockers: IssueHoldBlocker[],
    note: string | null,
    actor: HoldActor,
    setAt: Date,
  ): IssueHold {
    return {
      kind,
      blockers,
      note,
      reheld: false,
      setAt: setAt.toISOString(),
      setByAgentId: actor.agentId ?? null,
      setByUserId: actor.userId ?? null,
    };
  }

  /**
   * A hold a caller wrote as a field. A blocker that does not exist, or the
   * task itself, is refused here: the writer is still in the request and can
   * correct it, where a hold on a task nobody can find would never release.
   */
  async function fromInput(issueId: string, input: IssueHoldInput, actor: HoldActor): Promise<IssueHold> {
    const { blockers, missing } = await resolveBlockers(input.blockers);
    if (missing.length > 0) {
      throw unprocessable(`Hold names ${missing.length === 1 ? "a task" : "tasks"} that do not exist: ${missing.join(", ")}`);
    }
    if (blockers.some((blocker) => blocker.id === issueId)) {
      throw unprocessable("A task cannot be held on itself");
    }
    return stamped(input.kind, blockers, input.note ?? null, actor, new Date());
  }

  /**
   * The hold a `Held:` comment declares, for writers that have not moved to the
   * field. Nothing is refused on this path, because the comment is already the
   * caller's whole intent: a line whose blockers cannot all be found is kept as
   * kind `other` with the line as its note, so it is visible as a hold that
   * names no release rather than read as one that waits on fewer tasks.
   */
  async function fromComment(
    issueId: string,
    body: string,
    actor: HoldActor,
    setAt: Date = new Date(),
  ): Promise<IssueHold | null> {
    const parsed = parseHoldLine(body);
    if (!parsed) return null;
    const { blockers, missing } = await resolveBlockers(parsed.blockerIdentifiers);
    const unreadable = missing.length > 0 || blockers.some((blocker) => blocker.id === issueId);
    if (unreadable) {
      const line = body.trim().split("\n", 1)[0]!.replace(/^\s*Held:\s*/, "");
      return stamped("other", [], line, actor, setAt);
    }
    return stamped(parsed.kind, blockers, parsed.note, actor, setAt);
  }

  /**
   * Give every task the migration marked its hold, read from its newest `Held:`
   * comment. Runs at boot and finds nothing after the first time.
   */
  async function backfillHolds(): Promise<number> {
    const pending = await db
      .select({
        id: issues.id,
        status: issues.status,
        assigneeAgentId: issues.assigneeAgentId,
        assigneeUserId: issues.assigneeUserId,
      })
      .from(issues)
      .where(sql`${issues.hold}->>'kind' = ${HOLD_PENDING_BACKFILL}`);
    let held = 0;
    for (const issue of pending) {
      const comment = await db
        .select({
          body: issueComments.body,
          createdAt: issueComments.createdAt,
          authorAgentId: issueComments.authorAgentId,
          authorUserId: issueComments.authorUserId,
        })
        .from(issueComments)
        .where(and(eq(issueComments.issueId, issue.id), sql`${issueComments.body} ~ '^\\s*Held:'`))
        .orderBy(desc(issueComments.createdAt))
        .limit(1)
        .then((rows) => rows[0] ?? null);
      let hold = comment
        ? await fromComment(
            issue.id,
            comment.body,
            { agentId: comment.authorAgentId, userId: comment.authorUserId },
            comment.createdAt,
          )
        : null;
      if (hold) {
        const placement = holdPlacement(hold.kind, issue, {});
        if (placement.status !== issue.status || (issue.status === "blocked" && placement.assigned)) hold = null;
      }
      await db.update(issues).set({ hold }).where(eq(issues.id, issue.id));
      if (hold) held += 1;
    }
    return held;
  }

  return { fromInput, fromComment, backfillHolds };
}
