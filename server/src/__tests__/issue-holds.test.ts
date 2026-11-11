import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { eq, sql } from "drizzle-orm";
import { activityLog, agents, createDb, instanceSettings, issueComments, issues } from "@paperclipai/db";
import type { IssueHold } from "@paperclipai/shared";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueService } from "../services/issues.ts";
import { HOLD_PENDING_BACKFILL, issueHoldService } from "../services/issue-holds.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres issue hold tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("issue holds", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof issueService>;
  let holds!: ReturnType<typeof issueHoldService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  let counter = 0;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issue-holds-");
    db = createDb(tempDb.connectionString);
    svc = issueService(db);
    holds = issueHoldService(db);
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

  async function seedIssue(values: Partial<typeof issues.$inferInsert> = {}) {
    counter += 1;
    const id = randomUUID();
    const identifier = `AA-${counter}`;
    await db.insert(issues).values({ id, identifier, title: identifier, status: "backlog", priority: "medium", ...values });
    return { id, identifier };
  }

  async function seedAgent() {
    const id = randomUUID();
    await db.insert(agents).values({
      id,
      name: `Agent ${id.slice(0, 6)}`,
      role: "engineer",
      status: "active",
      adapterType: "claude_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    return id;
  }

  const read = (id: string) => db.select().from(issues).where(eq(issues.id, id)).then((rows) => rows[0]!);

  it("parks the task when a hold is set: blocked, nobody assigned", async () => {
    const agentId = await seedAgent();
    const blocker = await seedIssue();
    const task = await seedIssue({ status: "todo", assigneeAgentId: agentId });

    const hold = await holds.fromInput(task.id, { kind: "until_merge", blockers: [blocker.identifier], note: null }, {});
    const updated = await svc.update(task.id, { hold });

    expect(updated?.status).toBe("blocked");
    expect(updated?.assigneeAgentId).toBeNull();
    expect(updated?.hold).toMatchObject({
      kind: "until_merge",
      blockers: [{ id: blocker.id, identifier: blocker.identifier }],
      reheld: false,
    });
  });

  it("refuses a hold on a task that does not exist, or on the task itself", async () => {
    const task = await seedIssue();
    await expect(
      holds.fromInput(task.id, { kind: "until_pr", blockers: ["AA-99999"], note: null }, {}),
    ).rejects.toMatchObject({ status: 422 });
    await expect(
      holds.fromInput(task.id, { kind: "until_pr", blockers: [task.id], note: null }, {}),
    ).rejects.toMatchObject({ status: 422 });
  });

  it("refuses a hold on a status it cannot stand under, and an assignee on a blocked hold", async () => {
    const agentId = await seedAgent();
    const blocker = await seedIssue();
    const task = await seedIssue();
    const hold = await holds.fromInput(task.id, { kind: "until_merge", blockers: [blocker.id], note: null }, {});

    await expect(svc.update(task.id, { hold, status: "todo" })).rejects.toMatchObject({ status: 422 });
    await expect(svc.update(task.id, { hold, assigneeAgentId: agentId })).rejects.toMatchObject({ status: 422 });
    expect((await read(task.id)).hold).toBeNull();
  });

  it("clears the hold when the task leaves blocked, and marks the same hold reheld when written again", async () => {
    const blocker = await seedIssue();
    const task = await seedIssue();
    const input = { kind: "until_pr" as const, blockers: [blocker.identifier], note: null };

    await svc.update(task.id, { hold: await holds.fromInput(task.id, input, {}) });
    const released = await svc.update(task.id, { status: "backlog" });
    expect(released?.hold).toBeNull();
    expect(released?.releasedHold).toMatchObject({ kind: "until_pr" });

    const reheld = await svc.update(task.id, { hold: await holds.fromInput(task.id, input, {}) });
    expect(reheld?.hold?.reheld).toBe(true);

    // Restating the hold while it stands keeps the mark; a different condition starts clean.
    const restated = await svc.update(task.id, { hold: await holds.fromInput(task.id, input, {}) });
    expect(restated?.hold?.reheld).toBe(true);
    const tightened = await svc.update(task.id, {
      hold: await holds.fromInput(task.id, { ...input, kind: "until_merge" }, {}),
    });
    expect(tightened?.hold?.reheld).toBe(false);
  });

  it("keeps a Planner hold through todo and drops it once the task is picked up", async () => {
    const planner = await seedAgent();
    const task = await seedIssue();
    await svc.update(task.id, { hold: await holds.fromInput(task.id, { kind: "planner", blockers: [], note: "bad spec" }, {}) });

    const routed = await svc.update(task.id, { status: "todo", assigneeAgentId: planner });
    expect(routed?.hold?.kind).toBe("planner");
    expect(routed?.assigneeAgentId).toBe(planner);

    const started = await svc.update(task.id, { status: "in_progress" });
    expect(started?.hold).toBeNull();
  });

  it("clears the hold on an explicit null without moving the task", async () => {
    const task = await seedIssue();
    await svc.update(task.id, { hold: await holds.fromInput(task.id, { kind: "operator", blockers: [], note: null }, {}) });
    const cleared = await svc.update(task.id, { hold: null });
    expect(cleared?.status).toBe("blocked");
    expect(cleared?.hold).toBeNull();
    expect(cleared?.releasedHold?.kind).toBe("operator");
  });

  it("reads a Held: comment into a hold, and keeps one it cannot resolve as kind other", async () => {
    const blocker = await seedIssue();
    const task = await seedIssue();

    const readable = await holds.fromComment(task.id, `Held: until ${blocker.identifier} opens its PR — same file`, {});
    expect(readable).toMatchObject({ kind: "until_pr", blockers: [{ id: blocker.id }], note: "same file" });

    const unresolved = await holds.fromComment(task.id, "Held: until AA-99999 merges", {});
    expect(unresolved).toMatchObject({ kind: "other", blockers: [], note: "until AA-99999 merges" });

    expect(await holds.fromComment(task.id, "Rebased onto main.", {})).toBeNull();
  });

  it("backfills marked tasks from their newest Held: comment and leaves none marked", async () => {
    const blocker = await seedIssue();
    const held = await seedIssue({ status: "blocked" });
    const bare = await seedIssue({ status: "blocked" });
    const marker = { kind: HOLD_PENDING_BACKFILL } as unknown as IssueHold;
    await db.update(issues).set({ hold: marker }).where(sql`${issues.id} in (${held.id}, ${bare.id})`);
    await db.insert(issueComments).values([
      { issueId: held.id, body: "Held: waiting on AA-99999", createdAt: new Date("2026-01-01T00:00:00Z") },
      { issueId: held.id, body: `Held: until ${blocker.identifier} merges`, createdAt: new Date("2026-01-02T00:00:00Z") },
      { issueId: held.id, body: "Status note after the hold.", createdAt: new Date("2026-01-03T00:00:00Z") },
    ]);

    expect(await holds.backfillHolds()).toBe(1);
    expect((await read(held.id)).hold).toMatchObject({
      kind: "until_merge",
      blockers: [{ id: blocker.id }],
      setAt: "2026-01-02T00:00:00.000Z",
    });
    expect((await read(bare.id)).hold).toBeNull();
    expect(await holds.backfillHolds()).toBe(0);
  });

  it("drops the hold when the task is checked out", async () => {
    const agentId = await seedAgent();
    const task = await seedIssue();
    await svc.update(task.id, { hold: await holds.fromInput(task.id, { kind: "operator", blockers: [], note: null }, {}) });

    await svc.checkout(task.id, agentId, ["blocked"], null);
    const row = await read(task.id);
    expect(row.status).toBe("in_progress");
    expect(row.hold).toBeNull();
    expect(row.releasedHold?.kind).toBe("operator");
  });
});
