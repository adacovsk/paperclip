import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { activityLog, createDb } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import {
  pruneActivityDetails,
  trimActivityDetails,
} from "../services/activity-details-retention.ts";

const DAY = 24 * 60 * 60 * 1000;

describe("trimActivityDetails", () => {
  it("keeps the transition skeleton and drops payloads, recording what went", () => {
    const trimmed = trimActivityDetails({
      status: "done",
      identifier: "ISS-1",
      source: "comment",
      reopened: true,
      reopenedFrom: "done",
      description: "a very long description",
      bodySnippet: "hello",
      _previous: { status: "in_progress", description: "the old long text" },
    });

    expect(trimmed).toEqual({
      status: "done",
      identifier: "ISS-1",
      source: "comment",
      reopened: true,
      reopenedFrom: "done",
      _previous: { status: "in_progress" },
      _trimmed: ["_previous.description", "bodySnippet", "description"],
    });
  });

  it("drops a kept key whose value is not a scalar", () => {
    expect(trimActivityDetails({ status: { huge: "object" }, title: "T" })).toEqual({
      title: "T",
      _trimmed: ["status"],
    });
  });

  it("drops _previous entirely when nothing in it is kept", () => {
    expect(trimActivityDetails({ _previous: { description: "x" } })).toEqual({
      _trimmed: ["_previous.description"],
    });
  });

  it("marks an already-minimal row with an empty list", () => {
    expect(trimActivityDetails({ commentId: "c1", identifier: "ISS-2" })).toEqual({
      commentId: "c1",
      identifier: "ISS-2",
      _trimmed: [],
    });
  });

  it("is a fixed point on its own output", () => {
    const once = trimActivityDetails({ status: "todo", bodySnippet: "x", _previous: { title: "a", markdown: "b" } });
    expect(trimActivityDetails(once)).toEqual(once);
  });
});

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres activity-details tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("pruneActivityDetails", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  const now = new Date("2026-09-24T00:00:00.000Z");

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-activity-details-");
    db = createDb(tempDb.connectionString);
  }, 120_000);

  afterEach(async () => {
    await db.delete(activityLog);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function addRow(ageDays: number, details: Record<string, unknown> | null = defaultDetails()) {
    const id = randomUUID();
    await db.insert(activityLog).values({
      id,
      actorType: "user",
      actorId: "operator",
      action: "issue.updated",
      entityType: "issue",
      entityId: randomUUID(),
      details,
      createdAt: new Date(now.getTime() - ageDays * DAY),
    });
    return id;
  }

  function defaultDetails() {
    return {
      status: "done",
      identifier: "ISS-9",
      description: "d".repeat(2_000),
      _previous: { status: "in_progress", description: "p".repeat(2_000) },
    };
  }

  const read = async (id: string) =>
    db.select().from(activityLog).where(eq(activityLog.id, id)).then((rows) => rows[0]);

  it("trims details on a row past the window and keeps the row", async () => {
    const old = await addRow(100);

    const result = await pruneActivityDetails(db, { retentionDays: 90, now });

    expect(result.trimmedRows).toBe(1);
    const row = await read(old);
    expect(row).toBeDefined();
    expect(row.action).toBe("issue.updated");
    expect(row.details).toEqual({
      status: "done",
      identifier: "ISS-9",
      _previous: { status: "in_progress" },
      _trimmed: ["_previous.description", "description"],
    });
  });

  it("never deletes a row", async () => {
    for (let i = 0; i < 5; i += 1) await addRow(200 + i);
    await addRow(1);

    await pruneActivityDetails(db, { retentionDays: 90, now });

    expect(await db.select().from(activityLog)).toHaveLength(6);
  });

  it("leaves rows inside the window untouched", async () => {
    const recent = await addRow(10);

    const result = await pruneActivityDetails(db, { retentionDays: 90, now });

    expect(result.trimmedRows).toBe(0);
    expect((await read(recent)).details).toEqual(defaultDetails());
  });

  it("works through a backlog larger than one batch", async () => {
    for (let i = 0; i < 7; i += 1) await addRow(100 + i);

    const result = await pruneActivityDetails(db, { retentionDays: 90, now, batchSize: 3 });

    expect(result.trimmedRows).toBe(7);
    expect(result.batches).toBe(3);
    const rows = await db.select().from(activityLog);
    for (const row of rows) expect(row.details).toHaveProperty("_trimmed");
  });

  it("is idempotent — a second pass reports nothing to do", async () => {
    await addRow(100);
    await addRow(100, { commentId: "c1" });

    const first = await pruneActivityDetails(db, { retentionDays: 90, now });
    const second = await pruneActivityDetails(db, { retentionDays: 90, now });

    expect(first.trimmedRows).toBe(2);
    expect(second.trimmedRows).toBe(0);
  });

  it("skips rows with null or non-object details", async () => {
    const nullRow = await addRow(100, null);

    const result = await pruneActivityDetails(db, { retentionDays: 90, now });

    expect(result.trimmedRows).toBe(0);
    expect((await read(nullRow)).details).toBeNull();
  });

  it("refuses a non-positive retention", async () => {
    await expect(pruneActivityDetails(db, { retentionDays: 0, now })).rejects.toThrow(/positive retentionDays/);
    await expect(pruneActivityDetails(db, { retentionDays: -1, now })).rejects.toThrow(/positive retentionDays/);
  });
});
