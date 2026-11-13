import { and, asc, isNotNull, lt, sql } from "drizzle-orm";
import { type Db, activityLog } from "@paperclipai/db";

/**
 * Marker written into every row this trim has processed: the sorted list of the
 * keys it dropped (dotted for `_previous.*`), empty when nothing was dropped.
 *
 * It does two jobs. It makes the pass idempotent without re-reading rows that
 * are already minimal -- a row carrying the marker is never selected again --
 * and it tells a later reader that a key is missing because it was trimmed, not
 * because it was never written. The UI reads it for exactly that: an
 * `issue.updated` row whose `description` was trimmed still renders as
 * "updated the description".
 */
export const ACTIVITY_DETAILS_TRIMMED_KEY = "_trimmed";

/**
 * The `details` keys kept past the window. Everything else is dropped.
 *
 * Stated as an allowlist, the opposite choice from run-history's in-flight
 * exclusion, because the failure modes run the other way. Here a key someone
 * adds tomorrow is far more likely to be a payload (a body snippet, a field
 * dump, a whole changed description in `_previous`) than a skeleton field, and
 * an allowlist drops it by default; forgetting to list a small key costs a
 * little fidelity on rows already months old, while a denylist that missed a
 * payload key would quietly stop reclaiming anything.
 *
 * What is kept, and who reads it:
 * - `status`, `priority`, `assigneeAgentId`, `assigneeUserId` -- the issue
 *   timeline and activity feed render transitions from these, and with
 *   `_previous.status` they are what status-transition history is
 *   reconstructed from. Enum values and ids, a few bytes each.
 * - `identifier`, `issueIdentifier` -- the human issue key; live-update and
 *   activity links resolve through it.
 * - `source`, `reopened`, `reopenedFrom`, `updated` -- why a change happened
 *   (a comment, a run escalation, a reopen) and from which status.
 * - `commentId` -- links a comment to the run that wrote it on the issue page.
 * - `agentId` -- names the agent on heartbeat-run rows in the activity feed.
 * - `key`, `title` -- document and goal rows render as "<key> (<title>)";
 *   titles are short, bounded text.
 * - `_previous` -- kept as an object, filtered to the same keys, so
 *   `_previous.status` survives while a `_previous.description` does not.
 *
 * A kept key is kept only while its value is a scalar. Its name was listed for
 * a small value; if some action ever stores an object under `status` or
 * `source`, that is a payload and goes like any other.
 */
const KEPT_DETAIL_KEYS: ReadonlySet<string> = new Set([
  "status",
  "priority",
  "assigneeAgentId",
  "assigneeUserId",
  "identifier",
  "issueIdentifier",
  "source",
  "reopened",
  "reopenedFrom",
  "updated",
  "commentId",
  "agentId",
  "key",
  "title",
]);

const PREVIOUS_KEY = "_previous";

/** Small enough that one batch's UPDATE holds its row locks for milliseconds. */
const DEFAULT_BATCH_SIZE = 500;

export type PruneActivityDetailsOptions = {
  retentionDays: number;
  now?: Date;
  batchSize?: number;
};

export type PruneActivityDetailsResult = {
  cutoff: Date;
  trimmedRows: number;
  batches: number;
};

function isScalar(value: unknown): boolean {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Pure: the trimmed form of one row's `details`. Exported for tests. */
export function trimActivityDetails(details: Record<string, unknown>): Record<string, unknown> {
  const kept: Record<string, unknown> = {};
  const dropped: string[] = [];

  for (const [key, value] of Object.entries(details)) {
    if (key === ACTIVITY_DETAILS_TRIMMED_KEY) continue;
    if (key === PREVIOUS_KEY && isPlainObject(value)) {
      const previous: Record<string, unknown> = {};
      for (const [prevKey, prevValue] of Object.entries(value)) {
        if (KEPT_DETAIL_KEYS.has(prevKey) && isScalar(prevValue)) previous[prevKey] = prevValue;
        else dropped.push(`${PREVIOUS_KEY}.${prevKey}`);
      }
      if (Object.keys(previous).length > 0) kept[PREVIOUS_KEY] = previous;
      continue;
    }
    if (KEPT_DETAIL_KEYS.has(key) && isScalar(value)) kept[key] = value;
    else dropped.push(key);
  }

  const alreadyDropped = details[ACTIVITY_DETAILS_TRIMMED_KEY];
  if (Array.isArray(alreadyDropped)) {
    for (const key of alreadyDropped) if (typeof key === "string") dropped.push(key);
  }

  kept[ACTIVITY_DETAILS_TRIMMED_KEY] = [...new Set(dropped)].sort();
  return kept;
}

/**
 * Clear the bulky part of `activity_log.details` on rows older than
 * `retentionDays`.
 *
 * Rows are **never deleted**. The activity log is the audit trail, and every
 * column on it but `details` is a few fixed-width fields: who, what action, on
 * which entity, from which run, when. What grows the table is `details`, which
 * carries whatever the writing route chose to put there -- comment snippets,
 * full update payloads, a changed description's old text under `_previous`.
 * That content is read when the row is fresh (live toasts, the issue timeline)
 * and almost never after; the small keys in `KEPT_DETAIL_KEYS` are the part
 * still worth having in a year.
 *
 * Done in batches of `batchSize`, each its own statement with no surrounding
 * transaction, so the trim never holds locks across the whole backlog on a
 * table every request writes to. Progress is guaranteed because every selected
 * row gets the marker and so leaves the selection.
 *
 * The selection has no index of its own and re-walks processed rows each pass.
 * That is the same order of cost as the backup dump running on the same clock,
 * and cheaper than a partial index maintained on every insert.
 */
export async function pruneActivityDetails(
  db: Db,
  { retentionDays, now = new Date(), batchSize = DEFAULT_BATCH_SIZE }: PruneActivityDetailsOptions,
): Promise<PruneActivityDetailsResult> {
  if (!Number.isFinite(retentionDays) || retentionDays <= 0) {
    throw new Error(`pruneActivityDetails requires a positive retentionDays, got ${String(retentionDays)}`);
  }
  if (!Number.isInteger(batchSize) || batchSize <= 0) {
    throw new Error(`pruneActivityDetails requires a positive integer batchSize, got ${String(batchSize)}`);
  }

  const cutoff = new Date(now.getTime() - retentionDays * 24 * 60 * 60 * 1000);
  let trimmedRows = 0;
  let batches = 0;

  for (;;) {
    const rows = await db
      .select({ id: activityLog.id, details: activityLog.details })
      .from(activityLog)
      .where(
        and(
          lt(activityLog.createdAt, cutoff),
          isNotNull(activityLog.details),
          // Non-object details (only reachable through the raw activity POST)
          // have no keys to sort into kept and dropped; they are left alone.
          sql`jsonb_typeof(${activityLog.details}) = 'object'`,
          sql`NOT (${activityLog.details} ? ${ACTIVITY_DETAILS_TRIMMED_KEY})`,
        ),
      )
      .orderBy(asc(activityLog.createdAt), asc(activityLog.id))
      .limit(batchSize);

    if (rows.length === 0) break;

    const values = rows.map(
      (row) => sql`(${row.id}::uuid, ${JSON.stringify(trimActivityDetails(row.details ?? {}))}::jsonb)`,
    );
    await db.execute(sql`
      UPDATE ${activityLog} AS a
      SET details = v.details
      FROM (VALUES ${sql.join(values, sql`, `)}) AS v(id, details)
      WHERE a.id = v.id
    `);

    trimmedRows += rows.length;
    batches += 1;
    if (rows.length < batchSize) break;
  }

  return { cutoff, trimmedRows, batches };
}

export function formatPruneActivityDetailsResult(result: PruneActivityDetailsResult): string {
  return `${result.trimmedRows} activity row(s) trimmed in ${result.batches} batch(es) before ${result.cutoff.toISOString()}`;
}

/** Let the freed TOAST and heap space be reused; the UPDATEs leave it as dead tuples. */
export async function vacuumActivityLog(db: Db): Promise<void> {
  await db.execute(sql`VACUUM (ANALYZE) activity_log`);
}
