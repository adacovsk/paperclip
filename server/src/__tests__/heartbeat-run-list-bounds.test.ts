import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { agents, companies, createDb, heartbeatRuns } from "@paperclipai/db";
import { HEARTBEAT_RUN_LIST_DEFAULT_LIMIT } from "@paperclipai/shared";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres heartbeat run list tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

/**
 * Run lists grow with every agent run and never shrink, so an unbounded list query is
 * a latency bug that gets worse over time rather than a fixed cost. These tests pin
 * the two properties that keep it bounded: `list` caps rows even when the caller
 * passes no limit, and the badge probe returns one row per agent instead of history.
 */
describeEmbeddedPostgres("heartbeatService run list bounds", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof heartbeatService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  const companyId = randomUUID();
  const agentA = randomUUID();
  const agentB = randomUUID();

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-heartbeat-bounds-");
    db = createDb(tempDb.connectionString);
    svc = heartbeatService(db);
  }, 20_000);

  afterEach(async () => {
    await db.delete(heartbeatRuns);
    await db.delete(agents);
    await db.delete(companies);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function seedRuns(count: number) {
    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: `T${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`,
      requireOperatorApprovalForNewAgents: false,
    });

    await db.insert(agents).values(
      [agentA, agentB].map((id, index) => ({
        id,
        companyId,
        name: `Agent${index}`,
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      })),
    );

    const base = Date.UTC(2026, 0, 1);
    await db.insert(heartbeatRuns).values(
      Array.from({ length: count }, (_, i) => ({
        id: randomUUID(),
        companyId,
        agentId: i % 2 === 0 ? agentA : agentB,
        invocationSource: "scheduled" as const,
        // Ascending time: the last row inserted per agent is that agent's latest.
        status: i === count - 1 || i === count - 2 ? ("succeeded" as const) : ("failed" as const),
        createdAt: new Date(base + i * 1000),
        updatedAt: new Date(base + i * 1000),
      })),
    );
  }

  it("bounds the run list when the caller passes no limit", async () => {
    await seedRuns(HEARTBEAT_RUN_LIST_DEFAULT_LIMIT + 25);

    const runs = await svc.list(companyId);

    expect(runs).toHaveLength(HEARTBEAT_RUN_LIST_DEFAULT_LIMIT);
  });

  it("returns the newest runs first when it truncates", async () => {
    await seedRuns(HEARTBEAT_RUN_LIST_DEFAULT_LIMIT + 25);

    const runs = await svc.list(companyId);
    const timestamps = runs.map((run) => run.createdAt.getTime());

    expect(timestamps).toEqual([...timestamps].sort((a, b) => b - a));
    // Truncation must drop the oldest runs, not the newest.
    expect(runs.at(0)!.createdAt.getTime()).toBeGreaterThan(runs.at(-1)!.createdAt.getTime());
  });

  it("honours an explicit limit below the default", async () => {
    await seedRuns(50);

    const runs = await svc.list(companyId, undefined, 5);

    expect(runs).toHaveLength(5);
  });

  it("returns exactly one run per agent for the badge probe", async () => {
    await seedRuns(60);

    const latest = await svc.latestRunsByAgent(companyId);

    expect(latest).toHaveLength(2);
    expect(new Set(latest.map((run) => run.agentId))).toEqual(new Set([agentA, agentB]));
  });

  it("picks each agent's most recent run, not an arbitrary one", async () => {
    const count = 60;
    await seedRuns(count);

    const latest = await svc.latestRunsByAgent(companyId);

    // The final two seeded rows are the newest per agent and the only "succeeded" ones,
    // so status doubles as a marker that the newest row won.
    expect(latest.map((run) => run.status)).toEqual(["succeeded", "succeeded"]);
  });
});
