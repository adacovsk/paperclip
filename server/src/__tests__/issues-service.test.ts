import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  activityLog,
  agents,
  instanceSettings,
  createDb,
  issueComments,
  issueInboxArchives,
  issues,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueService } from "../services/issues.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres issue service tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("issueService.list participantAgentId", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof issueService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issues-service-");
    db = createDb(tempDb.connectionString);
    svc = issueService(db);
    // Starting embedded Postgres does not fit in 20s when the machine is busy —
    // this hook was timing out under a parallel run, not failing.
  }, 120_000);

  afterEach(async () => {
    await db.delete(issueComments);
    await db.delete(issueInboxArchives);
    await db.delete(activityLog);
    await db.delete(issues);
    await db.delete(agents);
    await db.delete(instanceSettings);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  it("returns issues an agent participated in across the supported signals", async () => {
    const agentId = randomUUID();
    const otherAgentId = randomUUID();

    await db.insert(agents).values([
      {
        id: agentId,
        name: "CodexCoder",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
      {
        id: otherAgentId,
        name: "OtherAgent",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
    ]);

    const assignedIssueId = randomUUID();
    const createdIssueId = randomUUID();
    const commentedIssueId = randomUUID();
    const activityIssueId = randomUUID();
    const excludedIssueId = randomUUID();

    await db.insert(issues).values([
      {
        id: assignedIssueId,
        title: "Assigned issue",
        status: "todo",
        priority: "medium",
        assigneeAgentId: agentId,
        createdByAgentId: otherAgentId,
      },
      {
        id: createdIssueId,
        title: "Created issue",
        status: "todo",
        priority: "medium",
        createdByAgentId: agentId,
      },
      {
        id: commentedIssueId,
        title: "Commented issue",
        status: "todo",
        priority: "medium",
        createdByAgentId: otherAgentId,
      },
      {
        id: activityIssueId,
        title: "Activity issue",
        status: "todo",
        priority: "medium",
        createdByAgentId: otherAgentId,
      },
      {
        id: excludedIssueId,
        title: "Excluded issue",
        status: "todo",
        priority: "medium",
        createdByAgentId: otherAgentId,
        assigneeAgentId: otherAgentId,
      },
    ]);

    await db.insert(issueComments).values({
      issueId: commentedIssueId,
      authorAgentId: agentId,
      body: "Investigating this issue.",
    });

    await db.insert(activityLog).values({
      actorType: "agent",
      actorId: agentId,
      action: "issue.updated",
      entityType: "issue",
      entityId: activityIssueId,
      agentId,
      details: { changed: true },
    });

    const result = await svc.list({ participantAgentId: agentId });
    const resultIds = new Set(result.map((issue) => issue.id));

    expect(resultIds).toEqual(new Set([
      assignedIssueId,
      createdIssueId,
      commentedIssueId,
      activityIssueId,
    ]));
    expect(resultIds.has(excludedIssueId)).toBe(false);
  });

  it("combines participation filtering with search", async () => {
    const agentId = randomUUID();

    await db.insert(agents).values({
      id: agentId,
      name: "CodexCoder",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });

    const matchedIssueId = randomUUID();
    const otherIssueId = randomUUID();

    await db.insert(issues).values([
      {
        id: matchedIssueId,
        title: "Invoice reconciliation",
        status: "todo",
        priority: "medium",
        createdByAgentId: agentId,
      },
      {
        id: otherIssueId,
        title: "Weekly planning",
        status: "todo",
        priority: "medium",
        createdByAgentId: agentId,
      },
    ]);

    const result = await svc.list({
      participantAgentId: agentId,
      q: "invoice",
    });

    expect(result.map((issue) => issue.id)).toEqual([matchedIssueId]);
  });

  it("hides archived inbox issues until new external activity arrives", async () => {
    const userId = "user-1";
    const otherUserId = "user-2";

    const visibleIssueId = randomUUID();
    const archivedIssueId = randomUUID();
    const resurfacedIssueId = randomUUID();

    await db.insert(issues).values([
      {
        id: visibleIssueId,
        title: "Visible issue",
        status: "todo",
        priority: "medium",
        createdByUserId: userId,
        createdAt: new Date("2026-03-26T10:00:00.000Z"),
        updatedAt: new Date("2026-03-26T10:00:00.000Z"),
      },
      {
        id: archivedIssueId,
        title: "Archived issue",
        status: "todo",
        priority: "medium",
        createdByUserId: userId,
        createdAt: new Date("2026-03-26T11:00:00.000Z"),
        updatedAt: new Date("2026-03-26T11:00:00.000Z"),
      },
      {
        id: resurfacedIssueId,
        title: "Resurfaced issue",
        status: "todo",
        priority: "medium",
        createdByUserId: userId,
        createdAt: new Date("2026-03-26T12:00:00.000Z"),
        updatedAt: new Date("2026-03-26T12:00:00.000Z"),
      },
    ]);

    await svc.archiveInbox(
      archivedIssueId,
      userId,
      new Date("2026-03-26T12:30:00.000Z"),
    );
    await svc.archiveInbox(
      resurfacedIssueId,
      userId,
      new Date("2026-03-26T13:00:00.000Z"),
    );

    await db.insert(issueComments).values({
      issueId: resurfacedIssueId,
      authorUserId: otherUserId,
      body: "This should bring the issue back into Mine.",
      createdAt: new Date("2026-03-26T13:30:00.000Z"),
      updatedAt: new Date("2026-03-26T13:30:00.000Z"),
    });

    const archivedFiltered = await svc.list({
      touchedByUserId: userId,
      inboxArchivedByUserId: userId,
    });

    expect(archivedFiltered.map((issue) => issue.id)).toEqual([
      resurfacedIssueId,
      visibleIssueId,
    ]);

    await svc.unarchiveInbox(archivedIssueId, userId);

    const afterUnarchive = await svc.list({
      touchedByUserId: userId,
      inboxArchivedByUserId: userId,
    });

    expect(new Set(afterUnarchive.map((issue) => issue.id))).toEqual(new Set([
      visibleIssueId,
      archivedIssueId,
      resurfacedIssueId,
    ]));
  });

  // The list projection nulls `description` to keep the body off the wire. A bare
  // NULL is indistinguishable from a genuinely empty body, so list rows must also
  // say that the column was withheld and how long the real one is — otherwise
  // "description is null" gets read as "this ticket has no body".
  it("bounds the list by limit, most recently updated first, and by updatedSince", async () => {
    const day = 24 * 60 * 60 * 1000;
    const now = Date.now();
    const oldId = randomUUID();
    const midId = randomUUID();
    const newId = randomUUID();
    await db.insert(issues).values([
      { id: oldId, title: "Old", status: "done", priority: "critical", updatedAt: new Date(now - 30 * day) },
      { id: midId, title: "Mid", status: "done", priority: "low", updatedAt: new Date(now - 5 * day) },
      { id: newId, title: "New", status: "done", priority: "low", updatedAt: new Date(now - day) },
    ]);

    // A limit ranks by recency, not priority: the critical issue is the oldest.
    const latestTwo = await svc.list({ status: "done", limit: 2 });
    expect(latestTwo.map((issue) => issue.id)).toEqual([newId, midId]);

    const sinceTwoWeeks = await svc.list({ status: "done", updatedSince: new Date(now - 14 * day) });
    expect(sinceTwoWeeks.map((issue) => issue.id).sort()).toEqual([midId, newId].sort());
  });

  it("numbers issues from the instance issue prefix and counter", async () => {
    const first = await svc.create({ title: "First" } as any);
    const second = await svc.create({ title: "Second" } as any);
    const [instance] = await db.select().from(instanceSettings);

    expect(first.identifier).toBe(`${instance!.issuePrefix}-${first.issueNumber}`);
    expect(second.issueNumber).toBe(first.issueNumber! + 1);
    expect(instance!.issueCounter).toBe(second.issueNumber);
  });

  it("marks the withheld description on list rows instead of returning a bare null", async () => {
    const body = "Full task body that no list view renders.";
    const withBody = await svc.create({ title: "Has a body", description: body } as any);
    const withoutBody = await svc.create({ title: "Has no body" } as any);

    const rows = await svc.list({});
    const bodyRow = rows.find((row) => row.id === withBody.id)! as any;
    const emptyRow = rows.find((row) => row.id === withoutBody.id)! as any;

    // Withheld, and self-describing about it.
    expect(bodyRow.description).toBeNull();
    expect(bodyRow.descriptionOmitted).toBe(true);
    expect(bodyRow.descriptionChars).toBe(body.length);

    // The genuinely empty one is now distinguishable from the withheld one.
    expect(emptyRow.descriptionChars).toBe(0);

    // getById still serves the real body, and does not claim to have withheld it.
    const detail = (await svc.getById(withBody.id)) as any;
    expect(detail?.description).toBe(body);
    expect(detail?.descriptionOmitted).toBeUndefined();
  });
});
