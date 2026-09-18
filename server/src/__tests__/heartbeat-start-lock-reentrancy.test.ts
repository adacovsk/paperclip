import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  agents,
  agentWakeupRequests,
  companies,
  createDb,
  heartbeatRuns,
  issues,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres start-lock tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

/**
 * The per-agent start lock is a promise chain, so a holder that never settles is
 * not slow — it is permanent, and it takes the agent's whole queue with it.
 *
 * The path that produced one: `startNextQueuedRunForAgent` holds the lock and an
 * advisory transaction, `claimQueuedRun` auto-cancels a run whose issue already
 * reached `done`, and the cancel promotes a deferred wakeup and asks for it to be
 * dispatched — re-entering the lock the caller is still inside. Neither promise
 * settles, the advisory transaction never commits, and every later dispatch for
 * that agent chains onto the dead link, the periodic `resumeQueuedRuns` sweep
 * included. Observed in the wild as 57 runs `queued`, none `running`, for 23.5
 * hours, with the agent still reporting `idle`.
 *
 * Both tests below deadlock on the unguarded code rather than failing, so each
 * carries a timeout well under the suite default: a hang here is the regression.
 */
describeEmbeddedPostgres("agent start lock re-entrancy", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-start-lock-reentrancy-");
    db = createDb(tempDb.connectionString);
  }, 60_000);

  afterAll(async () => {
    // The guard under test dispatches the nested call *detached*, so it can
    // still be mid-query when the last assertion returns. Tearing the database
    // down underneath it surfaces as an unhandled postgres error attributed to
    // this file, so let the detached work settle first.
    await new Promise((resolve) => setTimeout(resolve, 500));
    await tempDb?.cleanup();
  });

  /**
   * Seeds the exact shape that wedged: a queued run against an issue that has
   * already reached `done` (so `claimQueuedRun` will auto-cancel it) with a
   * second deferred wakeup behind it on the same issue (so the cancel has a
   * successor to promote, which is what triggers the nested dispatch).
   */
  async function seedFinishedIssueWithQueuedRun() {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const runId = randomUUID();
    const deferredWakeupId = randomUUID();
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
      name: "Worker",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: { heartbeat: { maxConcurrentRuns: 4, wakeOnDemand: true } },
      permissions: {},
    });

    // The run is inserted first: `issues.execution_run_id` is an FK onto it.
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId,
      invocationSource: "automation",
      triggerDetail: "system",
      status: "queued",
      contextSnapshot: { issueId },
      startedAt: null,
      createdAt: now,
      updatedAt: now,
    });

    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Finished before the queued run could be claimed",
      status: "done",
      priority: "medium",
      assigneeAgentId: agentId,
      executionRunId: runId,
      executionLockedAt: now,
      issueNumber: 1,
      identifier: `${issuePrefix}-1`,
    });

    // The successor the cancel will promote. Without it
    // `releaseIssueExecutionAndPromote` returns early and never re-enters.
    await db.insert(agentWakeupRequests).values({
      id: deferredWakeupId,
      companyId,
      agentId,
      source: "assignment",
      triggerDetail: "system",
      status: "deferred_issue_execution",
      reason: "issue_execution_deferred",
      payload: { issueId },
      requestedAt: now,
      createdAt: now,
      updatedAt: now,
    });

    return { companyId, agentId, issueId, runId, deferredWakeupId };
  }

  it("dispatches instead of deadlocking when an auto-cancel promotes a successor", async () => {
    const { agentId, runId } = await seedFinishedIssueWithQueuedRun();
    const heartbeat = heartbeatService(db);

    // On the unguarded code this promise never settles.
    await heartbeat.startNextQueuedRunForAgent(agentId);

    const [run] = await db
      .select({ status: heartbeatRuns.status, error: heartbeatRuns.error })
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.id, runId));

    expect(run?.status).toBe("cancelled");
    expect(run?.error).toContain("already done");
  }, 30_000);

  it("leaves the lock usable for the next caller", async () => {
    const { agentId } = await seedFinishedIssueWithQueuedRun();
    const heartbeat = heartbeatService(db);

    await heartbeat.startNextQueuedRunForAgent(agentId);

    // The regression is not the first call — it is every call after it. A lock
    // that was wedged rather than released makes this one hang forever, which
    // is what turned a single bad cancel into a day-long outage.
    await expect(heartbeat.startNextQueuedRunForAgent(agentId)).resolves.toBeDefined();
    await expect(heartbeat.resumeQueuedRuns()).resolves.toBeUndefined();
  }, 30_000);
});
