import { and, desc, eq, gte, inArray, not, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { agents, approvals, heartbeatRuns } from "@paperclipai/db";
import type { SidebarBadges } from "@paperclipai/shared";

const ACTIONABLE_APPROVAL_STATUSES = ["pending", "revision_requested"];
export const FAILED_HEARTBEAT_STATUSES = ["failed", "timed_out"];
// Only count a failed run toward the inbox badge if it happened within this
// window. Older failures get ignored — they're stale noise (e.g., hit an API
// rate limit overnight) and keep the badge stuck at "1" with nothing for the
// user to click on in the actual inbox view. Shared with the sidebar agent
// run dots (live-runs?includeRecentErrors) so "recently errored" means the
// same thing in both surfaces.
export const FAILED_HEARTBEAT_FRESHNESS_MS = 60 * 60 * 1000; // 1 hour

export function sidebarBadgeService(db: Db) {
  return {
    get: async (
      companyId: string,
      extra?: { joinRequests?: number; unreadTouchedIssues?: number },
    ): Promise<SidebarBadges> => {
      const actionableApprovals = await db
        .select({ count: sql<number>`count(*)` })
        .from(approvals)
        .where(
          and(
            eq(approvals.companyId, companyId),
            inArray(approvals.status, ACTIONABLE_APPROVAL_STATUSES),
          ),
        )
        .then((rows) => Number(rows[0]?.count ?? 0));

      // Bounding the scan by the freshness window returns the same answer: an
      // agent's latest run can only count if it falls inside the window, and any
      // run inside it is newer than every run outside. Unbounded, DISTINCT ON
      // sorts the whole run history on every page load.
      const freshnessCutoff = Date.now() - FAILED_HEARTBEAT_FRESHNESS_MS;
      const latestRunByAgent = await db
        .selectDistinctOn([heartbeatRuns.agentId], {
          runStatus: heartbeatRuns.status,
          runCreatedAt: heartbeatRuns.createdAt,
        })
        .from(heartbeatRuns)
        .innerJoin(agents, eq(heartbeatRuns.agentId, agents.id))
        .where(
          and(
            eq(heartbeatRuns.companyId, companyId),
            eq(agents.companyId, companyId),
            not(eq(agents.status, "terminated")),
            gte(heartbeatRuns.createdAt, new Date(freshnessCutoff)),
          ),
        )
        .orderBy(heartbeatRuns.agentId, desc(heartbeatRuns.createdAt));

      const failedRuns = latestRunByAgent.filter(
        (row) =>
          FAILED_HEARTBEAT_STATUSES.includes(row.runStatus) &&
          new Date(row.runCreatedAt).getTime() >= freshnessCutoff,
      ).length;

      const joinRequests = extra?.joinRequests ?? 0;
      const unreadTouchedIssues = extra?.unreadTouchedIssues ?? 0;
      return {
        inbox: actionableApprovals + failedRuns + joinRequests + unreadTouchedIssues,
        approvals: actionableApprovals,
        failedRuns,
        joinRequests,
      };
    },
  };
}
