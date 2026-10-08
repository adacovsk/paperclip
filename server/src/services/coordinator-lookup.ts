import { and, eq, notInArray } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { agents } from "@paperclipai/db";

/**
 * The company's Coordinator, the default next mover for anything with no live
 * stage of its own.
 *
 * Its own module rather than a heartbeat export: the REST mutation path needs the
 * same answer as the run executor, and importing the executor into a route pulls
 * the adapter and process machinery in behind it. One lookup, one definition, so
 * the two paths cannot disagree about who the Coordinator is.
 */
export async function coordinatorIdFor(db: Db, companyId: string): Promise<string | null> {
  return db
    .select({ id: agents.id })
    .from(agents)
    .where(and(eq(agents.companyId, companyId), eq(agents.role, "coordinator")))
    .limit(1)
    .then((rows) => rows[0]?.id ?? null);
}

/**
 * Who takes a stage-completion wake: the company's Advancer when one is live,
 * otherwise the Coordinator.
 *
 * Stage completions are most of the Coordinator's wakes, and most of those
 * resolve through a mechanical signal table (Worker committed on a clean tree
 * -> Review subtask; Reviewer done -> Verify). The Advancer is a `process`
 * agent that runs that table as a script and wakes the Coordinator only for the
 * rows that need judgment. A paused or terminated Advancer falls back here, so
 * turning it off restores the old routing with no other change.
 */
export async function stageAdvancerIdFor(db: Db, companyId: string): Promise<string | null> {
  const advancer = await db
    .select({ id: agents.id })
    .from(agents)
    .where(
      and(
        eq(agents.companyId, companyId),
        eq(agents.role, "advancer"),
        notInArray(agents.status, ["paused", "terminated", "pending_approval"]),
      ),
    )
    .limit(1)
    .then((rows) => rows[0]?.id ?? null);
  return advancer ?? coordinatorIdFor(db, companyId);
}
