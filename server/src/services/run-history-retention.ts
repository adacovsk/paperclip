import { and, isNotNull, lt, notInArray, or, sql } from "drizzle-orm";
import { type Db, heartbeatRunEvents, heartbeatRuns } from "@paperclipai/db";

/**
 * Statuses a run can still be written from. Everything else is finished and
 * safe to compact.
 *
 * Stated as the exclusion rather than as a list of terminal statuses on
 * purpose: an allowlist silently stops pruning the day a new terminal status
 * is added, and the failure is invisible -- the table just grows again. The
 * in-flight set is small, changes rarely, and getting it wrong is loud.
 *
 * A detached build legitimately sits in `running` for hours while its output is
 * still being produced, which is why age alone is not sufficient.
 */
const IN_FLIGHT_RUN_STATUSES = ["queued", "running"] as const;

export type PruneRunHistoryOptions = {
  retentionDays: number;
  now?: Date;
};

export type PruneRunHistoryResult = {
  cutoff: Date;
  compactedRuns: number;
  deletedEvents: number;
};

/**
 * Drop the bulky, write-once parts of run history past `retentionDays`.
 *
 * Run rows are **compacted, not deleted**. What makes the table big is a few
 * large columns -- on one instance `stdout_excerpt` alone was 42% of the entire
 * database, against 3% for every issue and comment in it -- while the rest of
 * the row is the part anything actually asks for later: which agent ran, when,
 * how long, what status, what error. Deleting rows to reclaim the columns would
 * throw away the cheap half to save the expensive one, and "when did this agent
 * last succeed" stops being answerable beyond the window.
 *
 * Nothing live reads a run this old. Cost reporting is served by `cost_events`,
 * the stall sweeps read the newest page, and session compaction counts only the
 * runs in the session it is about to resume.
 *
 * Event rows are deleted outright: they are per-run timeline detail with no
 * skeleton worth keeping once the run is beyond the window.
 */
export async function pruneRunHistory(
  db: Db,
  { retentionDays, now = new Date() }: PruneRunHistoryOptions,
): Promise<PruneRunHistoryResult> {
  if (!Number.isFinite(retentionDays) || retentionDays <= 0) {
    throw new Error(`pruneRunHistory requires a positive retentionDays, got ${String(retentionDays)}`);
  }

  const cutoff = new Date(now.getTime() - retentionDays * 24 * 60 * 60 * 1000);

  // Only touch rows that still carry something, so a second pass over an
  // already-pruned window reports 0 rather than rewriting every old row.
  const compacted = await db
    .update(heartbeatRuns)
    .set({ stdoutExcerpt: null, stderrExcerpt: null, resultJson: null, contextSnapshot: null })
    .where(
      and(
        lt(heartbeatRuns.createdAt, cutoff),
        notInArray(heartbeatRuns.status, [...IN_FLIGHT_RUN_STATUSES]),
        or(
          isNotNull(heartbeatRuns.stdoutExcerpt),
          isNotNull(heartbeatRuns.stderrExcerpt),
          isNotNull(heartbeatRuns.resultJson),
          isNotNull(heartbeatRuns.contextSnapshot),
        ),
      ),
    )
    .returning({ id: heartbeatRuns.id });

  const deletedEvents = await db
    .delete(heartbeatRunEvents)
    .where(lt(heartbeatRunEvents.createdAt, cutoff))
    .returning({ id: heartbeatRunEvents.id });

  return {
    cutoff,
    compactedRuns: compacted.length,
    deletedEvents: deletedEvents.length,
  };
}

export function formatPruneRunHistoryResult(result: PruneRunHistoryResult): string {
  return `${result.compactedRuns} run(s) compacted, ${result.deletedEvents} event(s) removed before ${result.cutoff.toISOString()}`;
}

/** Reclaim the space the compaction freed; TOAST pages are not returned by the UPDATE itself. */
export async function vacuumRunHistory(db: Db): Promise<void> {
  await db.execute(sql`VACUUM (ANALYZE) heartbeat_runs`);
  await db.execute(sql`VACUUM (ANALYZE) heartbeat_run_events`);
}
