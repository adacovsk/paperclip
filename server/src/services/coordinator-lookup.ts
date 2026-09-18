import { and, eq } from "drizzle-orm";
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
