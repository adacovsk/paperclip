import { eq, gte, inArray, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { agents, approvals, costEvents, heartbeatRuns, issues } from "@paperclipai/db";
import { budgetService } from "./budgets.js";
import { getOrCreateInstanceSettingsRow } from "./instance-settings.js";

export function dashboardService(db: Db) {
  const budgets = budgetService(db);
  return {
    summary: async () => {
      const instance = await getOrCreateInstanceSettingsRow(db);

      const agentRows = await db
        .select({ status: agents.status, count: sql<number>`count(*)` })
        .from(agents)
        .groupBy(agents.status);

      const taskRows = await db
        .select({ status: issues.status, count: sql<number>`count(*)` })
        .from(issues)
        .groupBy(issues.status);

      const pendingApprovals = await db
        .select({ count: sql<number>`count(*)` })
        .from(approvals)
        .where(eq(approvals.status, "pending"))
        .then((rows) => Number(rows[0]?.count ?? 0));

      // Per-agent queue depth — surfaces the "agent appears idle but has stuck queued
      // runs" failure mode. An agent with queued > 0 and running == 0 means wakes are
      // accumulating but never claiming; treat as stuck.
      const agentRunCounts = await db
        .select({
          agentId: heartbeatRuns.agentId,
          status: heartbeatRuns.status,
          count: sql<number>`count(*)`,
        })
        .from(heartbeatRuns)
        .where(inArray(heartbeatRuns.status, ["queued", "running"]))
        .groupBy(heartbeatRuns.agentId, heartbeatRuns.status);
      const queuedByAgent = new Map<string, number>();
      const runningByAgent = new Map<string, number>();
      for (const row of agentRunCounts) {
        const count = Number(row.count);
        if (row.status === "queued") queuedByAgent.set(row.agentId, count);
        else if (row.status === "running") runningByAgent.set(row.agentId, count);
      }
      let totalQueued = 0;
      let stuckAgents = 0;
      for (const [agentId, queued] of queuedByAgent) {
        totalQueued += queued;
        if ((runningByAgent.get(agentId) ?? 0) === 0) stuckAgents += 1;
      }

      const agentCounts: Record<string, number> = {
        active: 0,
        running: 0,
        paused: 0,
        error: 0,
      };
      for (const row of agentRows) {
        const count = Number(row.count);
        // "idle" agents are operational — count them as active
        const bucket = row.status === "idle" ? "active" : row.status;
        agentCounts[bucket] = (agentCounts[bucket] ?? 0) + count;
      }

      const taskCounts: Record<string, number> = {
        open: 0,
        inProgress: 0,
        blocked: 0,
        done: 0,
      };
      for (const row of taskRows) {
        const count = Number(row.count);
        if (row.status === "in_progress") taskCounts.inProgress += count;
        if (row.status === "blocked") taskCounts.blocked += count;
        if (row.status === "done") taskCounts.done += count;
        if (row.status !== "done" && row.status !== "cancelled") taskCounts.open += count;
      }

      const now = new Date();
      const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
      const [{ monthSpend }] = await db
        .select({
          monthSpend: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int`,
        })
        .from(costEvents)
        .where(gte(costEvents.occurredAt, monthStart));

      const monthSpendCents = Number(monthSpend);
      const utilization =
        instance.budgetMonthlyCents > 0
          ? (monthSpendCents / instance.budgetMonthlyCents) * 100
          : 0;
      const budgetOverview = await budgets.overview();

      return {
        agents: {
          active: agentCounts.active,
          running: agentCounts.running,
          paused: agentCounts.paused,
          error: agentCounts.error,
          queued: totalQueued,
          stuck: stuckAgents,
        },
        tasks: taskCounts,
        costs: {
          monthSpendCents,
          monthBudgetCents: instance.budgetMonthlyCents,
          monthUtilizationPercent: Number(utilization.toFixed(2)),
        },
        pendingApprovals,
        budgets: {
          activeIncidents: budgetOverview.activeIncidents.length,
          pendingApprovals: budgetOverview.pendingApprovalCount,
          pausedAgents: budgetOverview.pausedAgentCount,
          pausedProjects: budgetOverview.pausedProjectCount,
        },
      };
    },
  };
}
