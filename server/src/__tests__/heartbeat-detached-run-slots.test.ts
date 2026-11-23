import { randomUUID } from "node:crypto";
import { and, eq, inArray } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agents, createDb, heartbeatRuns } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres detached-run slot tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

/**
 * A detached run stands for work executing outside the server (a long build),
 * capped by its own semaphore. It must not occupy one of the agent's
 * `maxConcurrentRuns` slots: an agent capped at 1 that opens detached builds
 * back to back would otherwise never start its own queued runs.
 */
describeEmbeddedPostgres("maxConcurrentRuns and detached runs", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  const startedRunIds: string[] = [];

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-detached-run-slots-");
    db = createDb(tempDb.connectionString);
  }, 60_000);

  afterAll(async () => {
    // A claimed run executes in the background; let it settle before the
    // database goes away underneath it.
    const deadline = Date.now() + 15_000;
    while (startedRunIds.length > 0 && Date.now() < deadline) {
      const live = await db
        .select({ id: heartbeatRuns.id })
        .from(heartbeatRuns)
        .where(and(inArray(heartbeatRuns.id, startedRunIds), inArray(heartbeatRuns.status, ["queued", "running"])));
      if (live.length === 0) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    await tempDb?.cleanup();
  }, 30_000);

  async function seedAgentWithQueuedRun() {
    const agentId = randomUUID();
    const queuedRunId = randomUUID();
    const now = new Date();

    await db.insert(agents).values({
      id: agentId,
      name: "Dispatcher",
      role: "engineer",
      status: "idle",
      adapterType: "process",
      adapterConfig: { command: "true" },
      runtimeConfig: { heartbeat: { maxConcurrentRuns: 1, wakeOnDemand: true } },
      permissions: {},
    });
    await db.insert(heartbeatRuns).values({
      id: queuedRunId,
      agentId,
      invocationSource: "automation",
      triggerDetail: "system",
      status: "queued",
      contextSnapshot: {},
      createdAt: now,
      updatedAt: now,
    });
    return { agentId, queuedRunId };
  }

  async function statusOf(runId: string) {
    const [row] = await db
      .select({ status: heartbeatRuns.status })
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.id, runId));
    return row?.status;
  }

  it("starts a queued run while a detached run is running", async () => {
    const { agentId, queuedRunId } = await seedAgentWithQueuedRun();
    const heartbeat = heartbeatService(db);
    const detached = await heartbeat.openDetachedRun({ agentId, triggerDetail: "cargo build" });

    const claimed = await heartbeat.startNextQueuedRunForAgent(agentId);
    startedRunIds.push(...claimed.map((run) => run.id));

    expect(claimed.map((run) => run.id)).toEqual([queuedRunId]);
    expect(await statusOf(queuedRunId)).not.toBe("queued");
    expect(await statusOf(detached.id)).toBe("running");
  }, 30_000);

  it("keeps the slot held by a supervised running run", async () => {
    const { agentId, queuedRunId } = await seedAgentWithQueuedRun();
    const now = new Date();
    await db.insert(heartbeatRuns).values({
      agentId,
      invocationSource: "automation",
      triggerDetail: "system",
      status: "running",
      startedAt: now,
      contextSnapshot: {},
      createdAt: now,
      updatedAt: now,
    });
    const heartbeat = heartbeatService(db);

    const claimed = await heartbeat.startNextQueuedRunForAgent(agentId);

    expect(claimed).toEqual([]);
    expect(await statusOf(queuedRunId)).toBe("queued");
  }, 30_000);
});
