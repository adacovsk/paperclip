import { randomUUID } from "node:crypto";
import { spawn, type ChildProcess } from "node:child_process";
import { eq } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  agents,
  agentWakeupRequests,
  createDb,
  heartbeatRunEvents,
  heartbeatRuns,
  issues,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { runningProcesses } from "../adapters/index.ts";
import { heartbeatService } from "../services/heartbeat.ts";
const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres heartbeat recovery tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

function spawnAliveProcess() {
  return spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
    stdio: "ignore",
  });
}

describeEmbeddedPostgres("heartbeat orphaned process recovery", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  const childProcesses = new Set<ChildProcess>();

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-heartbeat-recovery-");
    db = createDb(tempDb.connectionString);
  }, 20_000);

  afterEach(async () => {
    runningProcesses.clear();
    for (const child of childProcesses) {
      child.kill("SIGKILL");
    }
    childProcesses.clear();
    await db.delete(issues);
    await db.delete(heartbeatRunEvents);
    await db.delete(heartbeatRuns);
    await db.delete(agentWakeupRequests);
    await db.delete(agents);
  });

  afterAll(async () => {
    for (const child of childProcesses) {
      child.kill("SIGKILL");
    }
    childProcesses.clear();
    runningProcesses.clear();
    await tempDb?.cleanup();
  });

  async function seedRunFixture(input?: {
    adapterType?: string;
    runStatus?: "running" | "queued" | "failed";
    processPid?: number | null;
    processLossRetryCount?: number;
    includeIssue?: boolean;
    runErrorCode?: string | null;
    runError?: string | null;
    invocationSource?: string;
  }) {
    const agentId = randomUUID();
    const runId = randomUUID();
    const wakeupRequestId = randomUUID();
    const issueId = randomUUID();
    const now = new Date("2026-03-19T00:00:00.000Z");
    const issuePrefix = `T${randomUUID().replace(/-/g, "").slice(0, 6).toUpperCase()}`;

    await db.insert(agents).values({
      id: agentId,
      name: "CodexCoder",
      role: "engineer",
      status: "paused",
      adapterType: input?.adapterType ?? "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });

    await db.insert(agentWakeupRequests).values({
      id: wakeupRequestId,
      agentId,
      source: "assignment",
      triggerDetail: "system",
      reason: "issue_assigned",
      payload: input?.includeIssue === false ? {} : { issueId },
      status: "claimed",
      runId,
      claimedAt: now,
    });

    await db.insert(heartbeatRuns).values({
      id: runId,
      agentId,
      invocationSource: input?.invocationSource ?? "assignment",
      triggerDetail: "system",
      status: input?.runStatus ?? "running",
      wakeupRequestId,
      contextSnapshot: input?.includeIssue === false ? {} : { issueId },
      processPid: input?.processPid ?? null,
      processLossRetryCount: input?.processLossRetryCount ?? 0,
      errorCode: input?.runErrorCode ?? null,
      error: input?.runError ?? null,
      startedAt: now,
      updatedAt: new Date("2026-03-19T00:00:00.000Z"),
    });

    if (input?.includeIssue !== false) {
      await db.insert(issues).values({
        id: issueId,
        title: "Recover local adapter after lost process",
        status: "in_progress",
        priority: "medium",
        assigneeAgentId: agentId,
        checkoutRunId: runId,
        executionRunId: runId,
        issueNumber: 1,
        identifier: `${issuePrefix}-1`,
      });
    }

    return { agentId, runId, wakeupRequestId, issueId };
  }

  it("keeps a local run active when the recorded pid is still alive", async () => {
    const child = spawnAliveProcess();
    childProcesses.add(child);
    expect(child.pid).toBeTypeOf("number");

    const { runId, wakeupRequestId } = await seedRunFixture({
      processPid: child.pid ?? null,
      includeIssue: false,
    });
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.reapOrphanedRuns();
    expect(result.reaped).toBe(0);

    const run = await heartbeat.getRun(runId);
    expect(run?.status).toBe("running");
    expect(run?.errorCode).toBe("process_detached");
    expect(run?.error).toContain(String(child.pid));

    const wakeup = await db
      .select()
      .from(agentWakeupRequests)
      .where(eq(agentWakeupRequests.id, wakeupRequestId))
      .then((rows) => rows[0] ?? null);
    expect(wakeup?.status).toBe("claimed");
  });

  // A detached run's work lives outside this process, so the generic reap is
  // wrong for it: the retry path below would re-dispatch the agent and start a
  // duplicate multi-hour build while the original is still compiling.
  it("never reaps or retries a detached run whose wrapper is alive", async () => {
    const { agentId, runId } = await seedRunFixture({
      adapterType: "claude_local",
      invocationSource: "detached_external",
      processPid: process.pid,
    });
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.reapOrphanedRuns();
    expect(result.reaped).toBe(0);

    const run = await heartbeat.getRun(runId);
    expect(run?.status).toBe("running");

    const runs = await db
      .select()
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(1);
  });

  // The recorded pid is the wrapper, which closes its run before exiting. Once
  // it is dead nothing else can settle the row, so the reaper settles it the
  // way the wrapper would have: failed, and still no retry.
  it("settles a detached run whose wrapper pid is dead, without a retry", async () => {
    const { agentId, runId } = await seedRunFixture({
      adapterType: "claude_local",
      invocationSource: "detached_external",
      processPid: 999_999_999,
    });
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.reapOrphanedRuns();
    expect(result.reaped).toBe(1);

    const run = await heartbeat.getRun(runId);
    expect(run?.status).toBe("failed");
    expect(run?.errorCode).toBe("detached_wrapper_lost");

    const runs = await db
      .select()
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(1);
  });

  it("cancels an issue's detached runs so the wrapper can tear the build down", async () => {
    const { runId, issueId } = await seedRunFixture({
      adapterType: "claude_local",
      invocationSource: "detached_external",
    });
    const heartbeat = heartbeatService(db);

    const cancelled = await heartbeat.cancelDetachedRunsForIssue(issueId, "Issue moved to blocked");
    expect(cancelled).toEqual([runId]);

    const run = await heartbeat.getRun(runId);
    expect(run?.status).toBe("cancelled");
    expect(run?.errorCode).toBe("detached_cancelled");

    // The wrapper's close must not overwrite a recorded cancellation with the
    // exit code of the build it just killed.
    await heartbeat.finishDetachedRun(runId, { exitCode: 143 });
    expect((await heartbeat.getRun(runId))?.status).toBe("cancelled");
  });

  it("queues exactly one retry when the recorded local pid is dead", async () => {
    const { agentId, runId, issueId } = await seedRunFixture({
      processPid: 999_999_999,
    });
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.reapOrphanedRuns();
    expect(result.reaped).toBe(1);
    expect(result.runIds).toEqual([runId]);

    const runs = await db
      .select()
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(2);

    const failedRun = runs.find((row) => row.id === runId);
    const retryRun = runs.find((row) => row.id !== runId);
    expect(failedRun?.status).toBe("failed");
    expect(failedRun?.errorCode).toBe("process_lost");
    expect(retryRun?.status).toBe("queued");
    expect(retryRun?.retryOfRunId).toBe(runId);
    expect(retryRun?.processLossRetryCount).toBe(1);

    const issue = await db
      .select()
      .from(issues)
      .where(eq(issues.id, issueId))
      .then((rows) => rows[0] ?? null);
    expect(issue?.executionRunId).toBe(retryRun?.id ?? null);
    expect(issue?.checkoutRunId).toBe(runId);
  });

  it("attributes the loss to the server shutdown that caused it", async () => {
    const { runId } = await seedRunFixture({ processPid: 999_999_999 });
    const heartbeat = heartbeatService(db);

    runningProcesses.set(runId, { child: { kill: () => true } as never, graceSec: 1 });
    const marked = await heartbeat.markRunsInterruptedByShutdown("SIGTERM");
    expect(marked).toBe(1);
    runningProcesses.delete(runId);

    await heartbeat.reapOrphanedRuns();

    const failedRun = await db
      .select()
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.id, runId))
      .then((rows) => rows[0] ?? null);
    expect(failedRun?.status).toBe("failed");
    expect(failedRun?.errorCode).toBe("process_lost");
    // The whole point: the record says the server killed it, not the bare
    // "child pid N is no longer running" that reads as child instability.
    expect(failedRun?.error).toContain("the server shut down");
    expect(failedRun?.error).toContain("SIGTERM");
  });

  it("does not queue a second retry after the first process-loss retry was already used", async () => {
    const { agentId, runId, issueId } = await seedRunFixture({
      processPid: 999_999_999,
      processLossRetryCount: 1,
    });
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.reapOrphanedRuns();
    expect(result.reaped).toBe(1);
    expect(result.runIds).toEqual([runId]);

    const runs = await db
      .select()
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(1);
    expect(runs[0]?.status).toBe("failed");

    const issue = await db
      .select()
      .from(issues)
      .where(eq(issues.id, issueId))
      .then((rows) => rows[0] ?? null);
    expect(issue?.executionRunId).toBeNull();
    expect(issue?.checkoutRunId).toBe(runId);
  });

  it("leaves the agent idle, not in error, when its run's process was lost", async () => {
    const { agentId } = await seedRunFixture({ processPid: 999_999_999, processLossRetryCount: 1 });
    await db.update(agents).set({ status: "running" }).where(eq(agents.id, agentId));
    const heartbeat = heartbeatService(db);

    await heartbeat.reapOrphanedRuns();

    const agent = await db.select().from(agents).where(eq(agents.id, agentId)).then((rows) => rows[0]);
    expect(agent?.status).toBe("idle");
  });

  it("retries a retry that a restart killed, and says the server shut down", async () => {
    const { agentId, runId } = await seedRunFixture({ processPid: 999_999_999, processLossRetryCount: 1 });
    const heartbeat = heartbeatService(db);

    await heartbeat.reapOrphanedRuns({ serverJustStarted: true });

    const runs = await db.select().from(heartbeatRuns).where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(2);
    const lost = runs.find((row) => row.id === runId);
    const retry = runs.find((row) => row.id !== runId);
    // No shutdown stamp was written, as when the database dies with the server.
    expect(lost?.error).toContain("the server shut down");
    expect(retry?.status).toBe("queued");
    expect(retry?.processLossRetryCount).toBe(2);
  });

  it("stops retrying a run that restarts keep killing", async () => {
    const { agentId, issueId } = await seedRunFixture({ processPid: 999_999_999, processLossRetryCount: 4 });
    const heartbeat = heartbeatService(db);

    await heartbeat.reapOrphanedRuns({ serverJustStarted: true });

    const runs = await db.select().from(heartbeatRuns).where(eq(heartbeatRuns.agentId, agentId));
    expect(runs).toHaveLength(1);
    const issue = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(issue?.executionRunId).toBeNull();
  });

  it("clears an error status a lost process left behind, and no other", async () => {
    const lost = await seedRunFixture({ runStatus: "failed", runErrorCode: "process_lost" });
    const broke = await seedRunFixture({ runStatus: "failed", runErrorCode: "adapter_failed" });
    const finishedAt = new Date("2026-03-19T00:05:00.000Z");
    await db.update(heartbeatRuns).set({ finishedAt });
    await db.update(agents).set({ status: "error" });
    const heartbeat = heartbeatService(db);

    expect(await heartbeat.clearProcessLostAgentErrors()).toBe(1);

    const statusOf = (id: string) =>
      db.select().from(agents).where(eq(agents.id, id)).then((rows) => rows[0]?.status);
    expect(await statusOf(lost.agentId)).toBe("idle");
    expect(await statusOf(broke.agentId)).toBe("error");
  });

  it("clears the detached warning when the run reports activity again", async () => {
    const { runId } = await seedRunFixture({
      includeIssue: false,
      runErrorCode: "process_detached",
      runError: "Lost in-memory process handle, but child pid 123 is still alive",
    });
    const heartbeat = heartbeatService(db);

    const updated = await heartbeat.reportRunActivity(runId);
    expect(updated?.errorCode).toBeNull();
    expect(updated?.error).toBeNull();

    const run = await heartbeat.getRun(runId);
    expect(run?.errorCode).toBeNull();
    expect(run?.error).toBeNull();
  });
});
