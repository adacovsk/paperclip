import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agents, companies, createDb, heartbeatRuns, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService, isOrphanedByUnassignment } from "../services/heartbeat.ts";

/**
 * A hold comments on an issue and clears its assignee in one breath. The comment
 * queues a wake for the assignee it had, and that run then fires against an issue
 * nobody owns: checking it out as `in_progress` is rejected, so every such run
 * failed `adapter_failed` and read as an agent fault. `claimQueuedRun` now cancels
 * it before it starts.
 */
describe("isOrphanedByUnassignment", () => {
  const unassigned = { assigneeAgentId: null, assigneeUserId: null };

  it("orphans a comment or sentinel wake on an unassigned issue", () => {
    expect(isOrphanedByUnassignment(unassigned, { wakeReason: "issue_commented" })).toBe(true);
    expect(isOrphanedByUnassignment(unassigned, { wakeReason: "verify-sentinel-ready" })).toBe(true);
    expect(isOrphanedByUnassignment(unassigned, {})).toBe(true);
  });

  it("keeps a run whose issue still has an assignee", () => {
    const wake = { wakeReason: "issue_commented" };
    expect(isOrphanedByUnassignment({ assigneeAgentId: randomUUID(), assigneeUserId: null }, wake)).toBe(false);
    expect(isOrphanedByUnassignment({ assigneeAgentId: null, assigneeUserId: "user-1" }, wake)).toBe(false);
  });

  it("honours an explicit mention on an unassigned issue", () => {
    expect(isOrphanedByUnassignment(unassigned, { wakeReason: "issue_comment_mentioned" })).toBe(false);
  });
});

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres unassigned-target tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("claimQueuedRun on an unassigned target issue", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-unassigned-target-");
    db = createDb(tempDb.connectionString);
  }, 60_000);

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  it("cancels a comment wake whose issue was unassigned before the run was claimed", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const runId = randomUUID();
    const issueId = randomUUID();
    const issuePrefix = `T${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`;
    const now = new Date();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix,
      requireOperatorApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Architect",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: { heartbeat: { maxConcurrentRuns: 4, wakeOnDemand: true } },
      permissions: {},
    });
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId,
      invocationSource: "automation",
      triggerDetail: "system",
      status: "queued",
      contextSnapshot: { issueId, wakeReason: "issue_commented" },
      startedAt: null,
      createdAt: now,
      updatedAt: now,
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Held and unassigned after the comment wake was queued",
      status: "todo",
      priority: "medium",
      issueNumber: 1,
      identifier: `${issuePrefix}-1`,
    });

    await heartbeatService(db).startNextQueuedRunForAgent(agentId);

    const [run] = await db
      .select({ status: heartbeatRuns.status, error: heartbeatRuns.error })
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.id, runId));
    expect(run?.status).toBe("cancelled");
    expect(run?.error).toContain("no longer assigned");
  }, 30_000);
});
