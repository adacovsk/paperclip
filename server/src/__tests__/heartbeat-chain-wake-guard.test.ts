import { describe, expect, it } from "vitest";
import { and, eq, inArray, ne, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/node-postgres";
import { issues } from "@paperclipai/db";
import { notWaitingOnForeignChildStage } from "../services/heartbeat.js";

const db = drizzle({} as never);

function renderCandidateQuery(agentId: string) {
  return db
    .select()
    .from(issues)
    .where(
      and(
        eq(issues.companyId, "company-1"),
        eq(issues.assigneeAgentId, agentId),
        ne(issues.id, "issue-just-processed"),
        inArray(issues.status, ["in_progress", "in_review", "todo"]),
        notWaitingOnForeignChildStage(agentId),
      ),
    )
    .limit(1)
    .toSQL();
}

describe("notWaitingOnForeignChildStage", () => {
  it("excludes in_review parents that still have a non-terminal child owned by another agent", () => {
    const { sql: text } = renderCandidateQuery("worker-agent");

    // The guard is scoped to in_review only — todo/in_progress tasks the agent
    // owns outright must stay selectable.
    expect(text).toContain(`"issues"."status" = 'in_review'`);
    expect(text).toContain(`child.parent_id = "issues"."id"`);
    // Terminal children do not block: a parent whose Verify child is done is
    // exactly the case chain-wake exists to advance.
    expect(text).toContain(`child.status NOT IN ('done', 'cancelled')`);
    // A child assigned back to the same agent is its own work, not a foreign
    // stage it is waiting on. IS DISTINCT FROM also treats an unassigned child
    // (NULL) as foreign, which is correct — nobody has picked it up yet.
    expect(text).toContain(`child.assignee_agent_id IS DISTINCT FROM`);
    expect(text).toMatch(/NOT \(/);
  });

  it("parameterizes the agent id rather than inlining it", () => {
    const { sql: text, params } = renderCandidateQuery("worker-agent");

    expect(text).not.toContain("worker-agent");
    // assignee filter + the guard's child comparison
    expect(params.filter((param) => param === "worker-agent")).toHaveLength(2);
  });
});
