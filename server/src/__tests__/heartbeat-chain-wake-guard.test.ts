import { describe, expect, it } from "vitest";
import { and, eq, inArray, ne, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/node-postgres";
import { issues } from "@paperclipai/db";
import { inReviewOnlyWhenOwnStageIsLive } from "../services/heartbeat.js";

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
        inReviewOnlyWhenOwnStageIsLive(agentId),
      ),
    )
    .limit(1)
    .toSQL();
}

describe("inReviewOnlyWhenOwnStageIsLive", () => {
  it("scopes the whole guard to in_review, leaving todo/in_progress selectable", () => {
    const { sql: text } = renderCandidateQuery("worker-agent");

    // The agent owns todo/in_progress work outright — chain-wake exists to
    // drain exactly that, so the guard must never reach it.
    expect(text).toContain(`"issues"."status" = 'in_review'`);
    expect(text).toMatch(/NOT \(/);
  });

  it("excludes in_review parents behind a live child owned by another agent (AA-2966)", () => {
    const { sql: text } = renderCandidateQuery("worker-agent");

    expect(text).toContain(`child.parent_id = "issues"."id"`);
    // Terminal children do not block: a parent whose Verify child is done is
    // exactly the case chain-wake exists to advance.
    expect(text).toContain(`child.status NOT IN ('done', 'cancelled')`);
    // A child assigned back to the same agent is its own work, not a foreign
    // stage it is waiting on. IS DISTINCT FROM also treats an unassigned child
    // (NULL) as foreign, which is correct — nobody has picked it up yet.
    expect(text).toContain(`child.assignee_agent_id IS DISTINCT FROM`);
  });

  it("excludes in_review parents with no open child at all (AA-4004)", () => {
    const { sql: text } = renderCandidateQuery("worker-agent");

    // The arm the foreign-child guard cannot see: nobody is working on it.
    // A Worker's stage ends at in_review, so with no live child of its own the
    // task is waiting on a merge or a next stage and no wake can advance it.
    expect(text).toContain("NOT EXISTS");
    expect(text).toContain(`own_child.parent_id = "issues"."id"`);
    expect(text).toContain(`own_child.status NOT IN ('done', 'cancelled')`);
    // Equality, not IS DISTINCT FROM: this arm asks whether the work is *mine*.
    expect(text).toContain("own_child.assignee_agent_id =");
  });

  it("keeps an in_review parent whose own child stage is still live", () => {
    const { sql: text } = renderCandidateQuery("architect-agent");

    // The no-skill Architect that commits without landing is re-dispatched
    // through this path; its task carries its own non-terminal verify subtask.
    // Both arms are OR'd inside the NOT, so satisfying neither keeps the task.
    expect(text).toMatch(/OR NOT EXISTS/);
  });

  it("parameterizes the agent id rather than inlining it", () => {
    const { sql: text, params } = renderCandidateQuery("worker-agent");

    expect(text).not.toContain("worker-agent");
    // assignee filter + one comparison in each of the guard's two arms
    expect(params.filter((param) => param === "worker-agent")).toHaveLength(3);
  });
});
