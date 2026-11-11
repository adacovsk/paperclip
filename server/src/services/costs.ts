import { and, desc, eq, gte, isNotNull, lt, lte, sql, type AnyColumn, type SQL } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { activityLog, agents, costEvents, instanceSettings, issues, projects } from "@paperclipai/db";
import { notFound } from "../errors.js";
import { budgetService, type BudgetServiceHooks } from "./budgets.js";
import { DEFAULT_SINGLETON_KEY, getOrCreateInstanceSettingsRow } from "./instance-settings.js";

export interface CostDateRange {
  from?: Date;
  to?: Date;
}

const METERED_BILLING_TYPE = "metered_api";
const SUBSCRIPTION_BILLING_TYPES = ["subscription_included", "subscription_overage"] as const;

const subscriptionBillingList = () =>
  sql.join(SUBSCRIPTION_BILLING_TYPES.map((value) => sql`${value}`), sql`, `);

/**
 * Sum of a token column across a group.
 *
 * Cast to bigint, NOT int4: `sum(int4)` in Postgres already widens to bigint, and the
 * explicit `::int` cast this replaces forced it back into int4's ~2.1B ceiling — which
 * threw "integer out of range" on any aggregate whose token total crossed it (e.g. the
 * instance-wide by-provider/by-biller rollups). `.mapWith(Number)` coerces the postgres
 * driver's bigint-as-string back to a JS number (safe: realistic token totals stay far
 * below Number.MAX_SAFE_INTEGER). Run counts and costCents keep `::int` — they are small
 * and the driver already returns int4 as a number.
 */
const tokenSum = (col: AnyColumn) =>
  sql<number>`coalesce(sum(${col}), 0)::bigint`.mapWith(Number);

/** As {@link tokenSum}, but restricted to subscription billing types. */
const subscriptionTokenSum = (col: AnyColumn) =>
  sql<number>`coalesce(sum(case when ${costEvents.billingType} in (${subscriptionBillingList()}) then ${col} else 0 end), 0)::bigint`.mapWith(
    Number,
  );

function currentUtcMonthWindow(now = new Date()) {
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth();
  return {
    start: new Date(Date.UTC(year, month, 1, 0, 0, 0, 0)),
    end: new Date(Date.UTC(year, month + 1, 1, 0, 0, 0, 0)),
  };
}

async function getMonthlySpendTotal(
  db: Db,
  scope: { agentId?: string | null } = {},
) {
  const { start, end } = currentUtcMonthWindow();
  const conditions = [
    gte(costEvents.occurredAt, start),
    lt(costEvents.occurredAt, end),
  ];
  if (scope.agentId) {
    conditions.push(eq(costEvents.agentId, scope.agentId));
  }
  const [row] = await db
    .select({
      total: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
    })
    .from(costEvents)
    .where(and(...conditions));
  return Number(row?.total ?? 0);
}

export function costService(db: Db, budgetHooks: BudgetServiceHooks = {}) {
  const budgets = budgetService(db, budgetHooks);
  return {
    createEvent: async (data: typeof costEvents.$inferInsert) => {
      const agent = await db
        .select()
        .from(agents)
        .where(eq(agents.id, data.agentId))
        .then((rows) => rows[0] ?? null);

      if (!agent) throw notFound("Agent not found");

      const event = await db
        .insert(costEvents)
        .values({
          ...data,
          biller: data.biller ?? data.provider,
          billingType: data.billingType ?? "unknown",
          cachedInputTokens: data.cachedInputTokens ?? 0,
        })
        .returning()
        .then((rows) => rows[0]);

      const [agentMonthSpend, instanceMonthSpend] = await Promise.all([
        getMonthlySpendTotal(db, { agentId: event.agentId }),
        getMonthlySpendTotal(db),
      ]);

      await db
        .update(agents)
        .set({
          spentMonthlyCents: agentMonthSpend,
          updatedAt: new Date(),
        })
        .where(eq(agents.id, event.agentId));

      await db
        .update(instanceSettings)
        .set({
          spentMonthlyCents: instanceMonthSpend,
          updatedAt: new Date(),
        })
        .where(eq(instanceSettings.singletonKey, DEFAULT_SINGLETON_KEY));

      await budgets.evaluateCostEvent(event);

      return event;
    },

    summary: async (range?: CostDateRange) => {
      const instance = await getOrCreateInstanceSettingsRow(db);

      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      const [{ total }] = await db
        .select({
          total: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
        })
        .from(costEvents)
        .where(and(...conditions));

      const spendCents = Number(total);
      const utilization =
        instance.budgetMonthlyCents > 0
          ? (spendCents / instance.budgetMonthlyCents) * 100
          : 0;

      return {
        spendCents,
        budgetCents: instance.budgetMonthlyCents,
        utilizationPercent: Number(utilization.toFixed(2)),
      };
    },

    byAgent: async (range?: CostDateRange) => {
      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      return db
        .select({
          agentId: costEvents.agentId,
          agentName: agents.name,
          agentStatus: agents.status,
          costCents: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
          inputTokens: tokenSum(costEvents.inputTokens),
          cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
          outputTokens: tokenSum(costEvents.outputTokens),
          apiRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} = ${METERED_BILLING_TYPE} then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} in (${subscriptionBillingList()}) then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionCachedInputTokens: subscriptionTokenSum(costEvents.cachedInputTokens),
          subscriptionInputTokens: subscriptionTokenSum(costEvents.inputTokens),
          subscriptionOutputTokens: subscriptionTokenSum(costEvents.outputTokens),
        })
        .from(costEvents)
        .leftJoin(agents, eq(costEvents.agentId, agents.id))
        .where(and(...conditions))
        .groupBy(costEvents.agentId, agents.name, agents.status)
        .orderBy(desc(sql`coalesce(sum(${costEvents.costCents}), 0)::int`));
    },

    byProvider: async (range?: CostDateRange) => {
      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      return db
        .select({
          provider: costEvents.provider,
          biller: costEvents.biller,
          billingType: costEvents.billingType,
          model: costEvents.model,
          costCents: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
          inputTokens: tokenSum(costEvents.inputTokens),
          cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
          outputTokens: tokenSum(costEvents.outputTokens),
          apiRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} = ${METERED_BILLING_TYPE} then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} in (${subscriptionBillingList()}) then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionCachedInputTokens: subscriptionTokenSum(costEvents.cachedInputTokens),
          subscriptionInputTokens: subscriptionTokenSum(costEvents.inputTokens),
          subscriptionOutputTokens: subscriptionTokenSum(costEvents.outputTokens),
        })
        .from(costEvents)
        .where(and(...conditions))
        .groupBy(costEvents.provider, costEvents.biller, costEvents.billingType, costEvents.model)
        .orderBy(desc(sql`coalesce(sum(${costEvents.costCents}), 0)::int`));
    },

    byBiller: async (range?: CostDateRange) => {
      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      return db
        .select({
          biller: costEvents.biller,
          costCents: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
          inputTokens: tokenSum(costEvents.inputTokens),
          cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
          outputTokens: tokenSum(costEvents.outputTokens),
          apiRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} = ${METERED_BILLING_TYPE} then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionRunCount:
            sql<number>`count(distinct case when ${costEvents.billingType} in (${subscriptionBillingList()}) then ${costEvents.heartbeatRunId} end)::int`,
          subscriptionCachedInputTokens: subscriptionTokenSum(costEvents.cachedInputTokens),
          subscriptionInputTokens: subscriptionTokenSum(costEvents.inputTokens),
          subscriptionOutputTokens: subscriptionTokenSum(costEvents.outputTokens),
          providerCount: sql<number>`count(distinct ${costEvents.provider})::int`,
          modelCount: sql<number>`count(distinct ${costEvents.model})::int`,
        })
        .from(costEvents)
        .where(and(...conditions))
        .groupBy(costEvents.biller)
        .orderBy(desc(sql`coalesce(sum(${costEvents.costCents}), 0)::int`));
    },

    /**
     * aggregates cost_events by provider for each of three rolling windows:
     * last 5 hours, last 24 hours, last 7 days.
     * purely internal consumption data, no external rate-limit sources.
     */
    windowSpend: async () => {
      const windows = [
        { label: "5h", hours: 5 },
        { label: "24h", hours: 24 },
        { label: "7d", hours: 168 },
      ] as const;

      const results = await Promise.all(
        windows.map(async ({ label, hours }) => {
          const since = new Date(Date.now() - hours * 60 * 60 * 1000);
          const rows = await db
            .select({
              provider: costEvents.provider,
              biller: sql<string>`case when count(distinct ${costEvents.biller}) = 1 then min(${costEvents.biller}) else 'mixed' end`,
              costCents: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
              inputTokens: tokenSum(costEvents.inputTokens),
              cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
              outputTokens: tokenSum(costEvents.outputTokens),
            })
            .from(costEvents)
            .where(gte(costEvents.occurredAt, since))
            .groupBy(costEvents.provider)
            .orderBy(desc(sql`coalesce(sum(${costEvents.costCents}), 0)::int`));

          return rows.map((row) => ({
            provider: row.provider,
            biller: row.biller,
            window: label as string,
            windowHours: hours,
            costCents: row.costCents,
            inputTokens: row.inputTokens,
            cachedInputTokens: row.cachedInputTokens,
            outputTokens: row.outputTokens,
          }));
        }),
      );

      return results.flat();
    },

    byAgentModel: async (range?: CostDateRange) => {
      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      // single query: group by agent + provider + model.
      // the (agentId, occurredAt) composite index covers this well.
      // order by provider + model for stable db-level ordering; cost-desc sort
      // within each agent's sub-rows is done client-side in the ui memo.
      return db
        .select({
          agentId: costEvents.agentId,
          agentName: agents.name,
          provider: costEvents.provider,
          biller: costEvents.biller,
          billingType: costEvents.billingType,
          model: costEvents.model,
          costCents: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
          inputTokens: tokenSum(costEvents.inputTokens),
          cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
          outputTokens: tokenSum(costEvents.outputTokens),
        })
        .from(costEvents)
        .leftJoin(agents, eq(costEvents.agentId, agents.id))
        .where(and(...conditions))
        .groupBy(
          costEvents.agentId,
          agents.name,
          costEvents.provider,
          costEvents.biller,
          costEvents.billingType,
          costEvents.model,
        )
        .orderBy(costEvents.provider, costEvents.biller, costEvents.billingType, costEvents.model);
    },

    byProject: async (range?: CostDateRange) => {
      const issueIdAsText = sql<string>`${issues.id}::text`;
      const runProjectLinks = db
        .selectDistinctOn([activityLog.runId, issues.projectId], {
          runId: activityLog.runId,
          projectId: issues.projectId,
        })
        .from(activityLog)
        .innerJoin(
          issues,
          and(
            eq(activityLog.entityType, "issue"),
            eq(activityLog.entityId, issueIdAsText),
          ),
        )
        .where(
          and(
            isNotNull(activityLog.runId),
            isNotNull(issues.projectId),
          ),
        )
        .orderBy(activityLog.runId, issues.projectId, desc(activityLog.createdAt))
        .as("run_project_links");

      const effectiveProjectId = sql<string | null>`coalesce(${costEvents.projectId}, ${runProjectLinks.projectId})`;
      const conditions: SQL[] = [];
      if (range?.from) conditions.push(gte(costEvents.occurredAt, range.from));
      if (range?.to) conditions.push(lte(costEvents.occurredAt, range.to));

      const costCentsExpr = sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`;

      return db
        .select({
          projectId: effectiveProjectId,
          projectName: projects.name,
          costCents: costCentsExpr,
          inputTokens: tokenSum(costEvents.inputTokens),
          cachedInputTokens: tokenSum(costEvents.cachedInputTokens),
          outputTokens: tokenSum(costEvents.outputTokens),
        })
        .from(costEvents)
        .leftJoin(runProjectLinks, eq(costEvents.heartbeatRunId, runProjectLinks.runId))
        .innerJoin(projects, sql`${projects.id} = ${effectiveProjectId}`)
        .where(and(...conditions, sql`${effectiveProjectId} is not null`))
        .groupBy(effectiveProjectId, projects.name)
        .orderBy(desc(costCentsExpr));
    },
  };
}
