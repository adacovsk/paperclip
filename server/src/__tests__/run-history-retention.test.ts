import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { agents, companies, createDb, heartbeatRunEvents, heartbeatRuns } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { pruneRunHistory } from "../services/run-history-retention.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres run-history tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

const DAY = 24 * 60 * 60 * 1000;

describeEmbeddedPostgres("pruneRunHistory", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  let companyId!: string;
  let agentId!: string;

  const now = new Date("2026-09-24T00:00:00.000Z");

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-run-history-");
    db = createDb(tempDb.connectionString);
  }, 120_000);

  beforeEach(async () => {
    companyId = randomUUID();
    agentId = randomUUID();
    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: `T${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`,
      requireOperatorApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Worker",
      role: "engineer",
      status: "active",
      adapterType: "claude_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
  });

  afterEach(async () => {
    await db.delete(heartbeatRunEvents);
    await db.delete(heartbeatRuns);
    await db.delete(agents);
    await db.delete(companies);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function addRun(opts: { ageDays: number; status: string }) {
    const id = randomUUID();
    await db.insert(heartbeatRuns).values({
      id,
      companyId,
      agentId,
      status: opts.status,
      stdoutExcerpt: "x".repeat(200),
      stderrExcerpt: "e".repeat(20),
      resultJson: { result: "done" },
      contextSnapshot: { issues: 3 },
      usageJson: { costUsd: 1.5 },
      error: "boom",
      createdAt: new Date(now.getTime() - opts.ageDays * DAY),
    });
    return id;
  }

  async function addEvent(runId: string, ageDays: number) {
    await db.insert(heartbeatRunEvents).values({
      companyId,
      runId,
      agentId,
      seq: 1,
      eventType: "stdout",
      payload: { line: "hello" },
      createdAt: new Date(now.getTime() - ageDays * DAY),
    });
  }

  const read = async (id: string) =>
    db.select().from(heartbeatRuns).where(eq(heartbeatRuns.id, id)).then((rows) => rows[0]);

  it("clears the bulky columns on a finished run past the window", async () => {
    const old = await addRun({ ageDays: 40, status: "succeeded" });

    const result = await pruneRunHistory(db, { retentionDays: 30, now });

    expect(result.compactedRuns).toBe(1);
    const row = await read(old);
    expect(row.stdoutExcerpt).toBeNull();
    expect(row.stderrExcerpt).toBeNull();
    expect(row.resultJson).toBeNull();
    expect(row.contextSnapshot).toBeNull();
  });

  it("keeps the skeleton that stall analysis reads", async () => {
    const old = await addRun({ ageDays: 40, status: "failed" });

    await pruneRunHistory(db, { retentionDays: 30, now });

    const row = await read(old);
    expect(row.status).toBe("failed");
    expect(row.agentId).toBe(agentId);
    expect(row.error).toBe("boom");
    expect(row.usageJson).toEqual({ costUsd: 1.5 });
  });

  it("leaves runs inside the window untouched", async () => {
    const recent = await addRun({ ageDays: 5, status: "succeeded" });

    const result = await pruneRunHistory(db, { retentionDays: 30, now });

    expect(result.compactedRuns).toBe(0);
    expect((await read(recent)).stdoutExcerpt).not.toBeNull();
  });

  it.each(["queued", "running"])("never touches an in-flight run, however old (%s)", async (status) => {
    const inFlight = await addRun({ ageDays: 400, status });

    const result = await pruneRunHistory(db, { retentionDays: 30, now });

    expect(result.compactedRuns).toBe(0);
    expect((await read(inFlight)).stdoutExcerpt).not.toBeNull();
  });

  it.each(["succeeded", "failed", "cancelled", "timed_out"])(
    "compacts every terminal status (%s)",
    async (status) => {
      await addRun({ ageDays: 40, status });
      const result = await pruneRunHistory(db, { retentionDays: 30, now });
      expect(result.compactedRuns).toBe(1);
    },
  );

  it("deletes run events past the window and keeps recent ones", async () => {
    const old = await addRun({ ageDays: 40, status: "succeeded" });
    const recent = await addRun({ ageDays: 2, status: "succeeded" });
    await addEvent(old, 40);
    await addEvent(recent, 2);

    const result = await pruneRunHistory(db, { retentionDays: 30, now });

    expect(result.deletedEvents).toBe(1);
    const remaining = await db.select().from(heartbeatRunEvents);
    expect(remaining).toHaveLength(1);
    expect(remaining[0].runId).toBe(recent);
  });

  it("is idempotent — a second pass reports nothing to do", async () => {
    await addRun({ ageDays: 40, status: "succeeded" });

    const first = await pruneRunHistory(db, { retentionDays: 30, now });
    const second = await pruneRunHistory(db, { retentionDays: 30, now });

    expect(first.compactedRuns).toBe(1);
    expect(second.compactedRuns).toBe(0);
  });

  it("refuses a non-positive retention rather than deleting everything", async () => {
    await expect(pruneRunHistory(db, { retentionDays: 0, now })).rejects.toThrow(/positive retentionDays/);
    await expect(pruneRunHistory(db, { retentionDays: -1, now })).rejects.toThrow(/positive retentionDays/);
  });
});
