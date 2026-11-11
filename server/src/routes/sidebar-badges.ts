import { Router } from "express";
import type { Db } from "@paperclipai/db";
import { eq, sql } from "drizzle-orm";
import { joinRequests } from "@paperclipai/db";
import { sidebarBadgeService } from "../services/sidebar-badges.js";
import { accessService } from "../services/access.js";
import { dashboardService } from "../services/dashboard.js";
import { assertInstanceAccess } from "./authz.js";

export function sidebarBadgeRoutes(db: Db) {
  const router = Router();
  const svc = sidebarBadgeService(db);
  const access = accessService(db);
  const dashboard = dashboardService(db);

  router.get("/sidebar-badges", async (req, res) => {
    assertInstanceAccess(req);
    let canApproveJoins = false;
    if (req.actor.type === "operator") {
      canApproveJoins =
        req.actor.source === "local_implicit" ||
        Boolean(req.actor.isInstanceAdmin) ||
        (await access.canUser(req.actor.userId, "joins:approve"));
    } else if (req.actor.type === "agent" && req.actor.agentId) {
      canApproveJoins = await access.hasPermission("agent", req.actor.agentId, "joins:approve");
    }

    const joinRequestCount = canApproveJoins
      ? await db
        .select({ count: sql<number>`count(*)` })
        .from(joinRequests)
        .where(eq(joinRequests.status, "pending_approval"))
        .then((rows) => Number(rows[0]?.count ?? 0))
      : 0;

    const badges = await svc.get({
      joinRequests: joinRequestCount,
    });
    const summary = await dashboard.summary();
    const hasFailedRuns = badges.failedRuns > 0;
    const alertsCount =
      (summary.agents.error > 0 && !hasFailedRuns ? 1 : 0) +
      (summary.costs.monthBudgetCents > 0 && summary.costs.monthUtilizationPercent >= 80 ? 1 : 0);
    badges.inbox = badges.failedRuns + alertsCount + joinRequestCount + badges.approvals;

    res.json(badges);
  });

  return router;
}
