import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { activityLog, agents, createDb, instanceSettings, issueComments, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueService } from "../services/issues.ts";

// These run against real Postgres on purpose. The defect they cover lives in the
// shape of the error the driver raises, so a fake that throws a hand-built
// `{ code, constraint }` would pass against the broken predicate too.
const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres subtask dedupe tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("issueService.create open-subtask dedupe", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof issueService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-subtask-dedupe-");
    db = createDb(tempDb.connectionString);
    svc = issueService(db);
  }, 120_000);

  afterEach(async () => {
    await db.delete(issueComments);
    await db.delete(activityLog);
    await db.delete(issues);
    await db.delete(agents);
    await db.delete(instanceSettings);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function createParent() {
    return svc.create({
      title: "Parent task",
      description: "A parent that stage subtasks hang off.",
      status: "in_review",
    } as Parameters<typeof svc.create>[0]);
  }

  it("returns the existing open subtask instead of failing the duplicate create", async () => {
    const parent = await createParent();

    const first = await svc.create({
      parentId: parent.id,
      dedupeKey: "verify",
      title: "Verify: first",
      description: "The stage subtask that wins the race.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    const second = await svc.create({
      parentId: parent.id,
      dedupeKey: "verify",
      title: "Verify: second",
      description: "The stage subtask that loses the race.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    // Create-or-get, not create-again and not a 500.
    expect(second.id).toBe(first.id);
    expect(second.title).toBe("Verify: first");

    const children = await db.select().from(issues);
    expect(children.filter((row) => row.parentId === parent.id)).toHaveLength(1);
  });

  it("resolves concurrent duplicate creates to one subtask", async () => {
    const parent = await createParent();

    // The race the partial unique index was added to close: both callers see no
    // existing subtask, both insert, one gets 23505.
    const results = await Promise.all(
      [1, 2, 3].map((n) =>
        svc.create({
          parentId: parent.id,
          dedupeKey: "review",
          title: `Review: caller ${n}`,
          description: "One of several concurrent stage-subtask creates.",
          status: "todo",
        } as Parameters<typeof svc.create>[0]),
      ),
    );

    const ids = new Set(results.map((issue) => issue.id));
    expect(ids.size).toBe(1);

    const children = await db.select().from(issues);
    expect(children.filter((row) => row.parentId === parent.id)).toHaveLength(1);
  });

  it("allows a second subtask once the first is no longer open", async () => {
    const parent = await createParent();

    const first = await svc.create({
      parentId: parent.id,
      dedupeKey: "verify",
      title: "Verify: first attempt",
      description: "The stage subtask that finishes.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    await svc.update(first.id, { status: "done" });

    const second = await svc.create({
      parentId: parent.id,
      dedupeKey: "verify",
      title: "Verify: second attempt",
      description: "A fresh stage subtask after the first one closed.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    expect(second.id).not.toBe(first.id);
  });

  it("keeps the same dedupeKey independent across parents", async () => {
    const parentA = await createParent();
    const parentB = await createParent();

    const a = await svc.create({
      parentId: parentA.id,
      dedupeKey: "verify",
      title: "Verify: parent A",
      description: "Stage subtask under the first parent.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    const b = await svc.create({
      parentId: parentB.id,
      dedupeKey: "verify",
      title: "Verify: parent B",
      description: "Stage subtask under the second parent.",
      status: "todo",
    } as Parameters<typeof svc.create>[0]);

    expect(b.id).not.toBe(a.id);
  });
});
