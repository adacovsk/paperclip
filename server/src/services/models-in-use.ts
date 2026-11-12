import { and, desc, eq, gte, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { agents, costEvents } from "@paperclipai/db";

/** How far back a model counts as in use. */
export const MODELS_IN_USE_WINDOW_DAYS = 30;

export interface ModelInUse {
  id: string;
  label: string;
}

/**
 * `claude-opus-5-5` -> `Claude Opus 5.5`. An id in another shape is shown as it
 * is: a label is a convenience, and a guessed one would be worse than the id.
 */
export function labelForClaudeModel(id: string): string {
  const m = /^claude-([a-z]+)-(\d{1,2}(?:-\d{1,2})*)(?:-\d{8})?$/.exec(id);
  if (!m) return id;
  const family = m[1]!.charAt(0).toUpperCase() + m[1]!.slice(1);
  return `Claude ${family} ${m[2]!.replace(/-/g, ".")}`;
}

/**
 * The models an adapter's agents actually ran recently, newest use first, and
 * the models they are configured with now.
 *
 * This is the list a model picker shows instead of a hard-coded one. A
 * hard-coded list is out of date from the first release after it is written:
 * the one this replaces topped out two generations behind the models every
 * agent was already on. The id each run reports is the model the CLI actually
 * resolved, so nothing here can name a model that does not exist. A model no
 * agent has run yet is typed into the picker once, and is listed from then on.
 */
export async function modelsInUse(db: Db, adapterType: string, now = new Date()): Promise<ModelInUse[]> {
  const since = new Date(now.getTime() - MODELS_IN_USE_WINDOW_DAYS * 24 * 60 * 60 * 1000);
  const ran = await db
    .select({ model: costEvents.model, lastUsed: sql<Date>`max(${costEvents.occurredAt})` })
    .from(costEvents)
    .innerJoin(agents, eq(costEvents.agentId, agents.id))
    .where(and(eq(agents.adapterType, adapterType), gte(costEvents.occurredAt, since)))
    .groupBy(costEvents.model)
    .orderBy(desc(sql`max(${costEvents.occurredAt})`));
  const configured = await db
    .select({ adapterConfig: agents.adapterConfig })
    .from(agents)
    .where(eq(agents.adapterType, adapterType));

  const ids: string[] = [];
  const add = (id: unknown) => {
    if (typeof id === "string" && id.trim() && !ids.includes(id.trim())) ids.push(id.trim());
  };
  for (const row of ran) add(row.model);
  for (const row of configured) add((row.adapterConfig as Record<string, unknown> | null)?.model);
  return ids.map((id) => ({ id, label: labelForClaudeModel(id) }));
}
