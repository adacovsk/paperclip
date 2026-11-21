import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { activityLog, agents, createDb, heartbeatRuns, instanceSettings, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueService } from "../services/issues.ts";
import {
  ISSUE_STATUS_CHANGED_ACTION,
  ISSUE_STATUS_TRANSITION_FLAGGED_ACTION,
  ISSUE_STATUS_TRANSITIONS,
  writeIssueStatus,
} from "../services/issue-status.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres issue status tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

const agentActor = (agentId: string, runId: string | null = null) => ({
  actorType: "agent" as const,
  actorId: agentId,
  agentId,
  runId,
});

describeEmbeddedPostgres("writeIssueStatus", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof issueService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issue-status-");
    db = createDb(tempDb.connectionString);
    svc = issueService(db);
  }, 120_000);

  afterEach(async () => {
    await db.delete(activityLog);
    await db.delete(issues);
    await db.delete(heartbeatRuns);
    await db.delete(agents);
    await db.delete(instanceSettings);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function seedAgent() {
    const agentId = randomUUID();
    await db.insert(agents).values({
      id: agentId,
      name: `Agent-${agentId.slice(0, 6)}`,
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    return agentId;
  }

  async function seedRun(agentId: string) {
    const runId = randomUUID();
    await db.insert(heartbeatRuns).values({
      id: runId,
      agentId,
      invocationSource: "automation",
      triggerDetail: "system",
      status: "running",
      contextSnapshot: {},
    });
    return runId;
  }

  async function seedIssue(values: Partial<typeof issues.$inferInsert> = {}) {
    const id = randomUUID();
    await db.insert(issues).values({ id, title: "Task", status: "todo", priority: "medium", ...values });
    return id;
  }

  function statusRows(issueId: string) {
    return db
      .select()
      .from(activityLog)
      .where(eq(activityLog.entityId, issueId))
      .then((rows) => rows.filter((row) => row.action === ISSUE_STATUS_CHANGED_ACTION));
  }

  function statusOf(issueId: string) {
    return db
      .select({ status: issues.status })
      .from(issues)
      .where(eq(issues.id, issueId))
      .then((rows) => rows[0]?.status);
  }

  function flagRows(issueId: string) {
    return db
      .select()
      .from(activityLog)
      .where(eq(activityLog.entityId, issueId))
      .then((rows) => rows.filter((row) => row.action === ISSUE_STATUS_TRANSITION_FLAGGED_ACTION));
  }

  it("refuses a rejected move with a 409, writes nothing, and still records the flag", async () => {
    const agentId = await seedAgent();
    const runId = await seedRun(agentId);
    const issueId = await seedIssue({ status: "cancelled" });

    await expect(
      writeIssueStatus(db, {
        issueId,
        set: { status: "done" },
        context: { actor: agentActor(agentId, runId), source: "issue_patch" },
      }),
    ).rejects.toMatchObject({ status: 409, details: { from: "cancelled", to: "done", flags: ["rejected"] } });

    expect(await statusOf(issueId)).toBe("cancelled");
    const flags = await flagRows(issueId);
    expect(flags).toHaveLength(1);
    expect(flags[0]).toMatchObject({ actorType: "system", actorId: "issue_status_table", agentId: null, runId: null });
    expect(flags[0].details).toMatchObject({
      status: "done",
      _previous: { status: "cancelled" },
      source: "issue_patch",
      flags: ["rejected"],
      actor: { actorType: "agent", actorId: agentId, runId },
      refused: true,
    });
    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("refuses every reject and operator cell to an agent and to the server", async () => {
    const agentId = await seedAgent();
    const refusedPairs = Object.entries(ISSUE_STATUS_TRANSITIONS).flatMap(([from, row]) =>
      Object.entries(row).filter(([, rule]) => rule !== "allow").map(([to]) => [from, to] as const));
    expect(refusedPairs.length).toBeGreaterThan(0);

    for (const [from, to] of refusedPairs) {
      for (const actor of [agentActor(agentId), { actorType: "system" as const, actorId: "issue_service" }]) {
        const issueId = await seedIssue({ status: from });
        await expect(
          writeIssueStatus(db, { issueId, set: { status: to }, context: { actor, source: "issue_patch" } }),
          `${from} -> ${to} by ${actor.actorType}`,
        ).rejects.toMatchObject({ status: 409 });
        expect(await statusOf(issueId), `${from} -> ${to} by ${actor.actorType}`).toBe(from);
      }
    }
  });

  it("lets the operator make any refused move, and records it as flagged but not refused", async () => {
    const operator = { actorType: "user" as const, actorId: "local-operator" };
    const rejected = await seedIssue({ status: "done" });
    const operatorOnly = await seedIssue({ status: "cancelled" });

    await writeIssueStatus(db, { issueId: rejected, set: { status: "cancelled" }, context: { actor: operator, source: "issue_patch" } });
    await writeIssueStatus(db, { issueId: operatorOnly, set: { status: "in_review" }, context: { actor: operator, source: "issue_patch" } });

    expect(await statusOf(rejected)).toBe("cancelled");
    expect(await statusOf(operatorOnly)).toBe("in_review");
    expect((await flagRows(rejected)).map((row) => row.details)).toMatchObject([{ flags: ["rejected"], refused: false }]);
    expect(await flagRows(operatorOnly)).toHaveLength(0);
  });

  it("skips, not throws, a refused move the server makes at a run's start or end", async () => {
    const agentId = await seedAgent();
    for (const source of ["no_skill_run_start", "no_skill_completion", "run_escalation"] as const) {
      const issueId = await seedIssue({ status: "done" });

      const result = await svc.update(issueId, { status: "blocked" }, { actor: agentActor(agentId), source });

      expect(result, source).toBeNull();
      expect(await statusOf(issueId), source).toBe("done");
      expect((await flagRows(issueId)).map((row) => row.details), source).toMatchObject([{ flags: ["rejected"], refused: true, source }]);
    }
  });

  it("does not refuse a move its guard would have skipped", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "done" });

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "blocked" },
      where: eq(issues.status, "in_review"),
      context: { actor: agentActor(agentId), source: "issue_patch" },
    });

    expect(result).toBeNull();
    expect(await statusOf(issueId)).toBe("done");
    expect(await flagRows(issueId)).toHaveLength(0);
  });

  it("refuses through update(), rolls its transaction back, and keeps the flag row", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "in_review", title: "Before" });

    await expect(
      svc.update(issueId, { status: "backlog", title: "After" }, { actor: agentActor(agentId), source: "issue_patch", statusLoggedByCaller: true }),
    ).rejects.toMatchObject({ status: 409 });

    const row = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(row).toMatchObject({ status: "in_review", title: "Before" });
    expect((await flagRows(issueId)).map((flag) => flag.details)).toMatchObject([{ flags: ["rejected"], refused: true }]);
  });

  it("lets a move through whose flag is not a refusing kind", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "todo" });

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "in_progress" },
      context: { actor: agentActor(agentId), source: "issue_patch" },
    });

    expect(result?.row.status).toBe("in_progress");
    expect((await flagRows(issueId)).map((row) => row.details)).toMatchObject([{ flags: ["in_progress_without_run"], refused: false }]);
    expect(await statusRows(issueId)).toHaveLength(1);
  });

  it("flags even when the caller logs the transition itself", async () => {
    const issueId = await seedIssue({ status: "done" });

    await writeIssueStatus(db, {
      issueId,
      set: { status: "blocked" },
      context: { actor: { actorType: "user", actorId: "local-operator" }, source: "issue_patch" },
      skipActivity: true,
    });

    expect(await statusRows(issueId)).toHaveLength(0);
    expect((await flagRows(issueId)).map((row) => (row.details as Record<string, unknown>).flags)).toEqual([["rejected"]]);
  });

  it("leaves a move made since the caller's read standing when update is guarded", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "in_progress", assigneeAgentId: agentId });
    // The operator cancels after a run's completion read `in_progress`.
    await db.update(issues).set({ status: "cancelled" }).where(eq(issues.id, issueId));

    const result = await svc.update(
      issueId,
      { status: "in_review" },
      { actor: agentActor(agentId), source: "no_skill_completion" },
      { expectedStatuses: ["in_progress"] },
    );

    expect(result).toBeNull();
    const row = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(row.status).toBe("cancelled");
    expect(await statusRows(issueId)).toHaveLength(0);
    expect(await flagRows(issueId)).toHaveLength(0);
  });

  it("skips, not throws, a guarded update whose task a hold parked since the caller's read", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "todo", assigneeAgentId: agentId });
    // A hold parks the task after run start read `todo`: blocked, nobody assigned.
    // Unguarded validation would throw "in_progress issues require an assignee".
    await db.update(issues).set({ status: "blocked", assigneeAgentId: null }).where(eq(issues.id, issueId));

    const result = await svc.update(
      issueId,
      { status: "in_progress" },
      { actor: agentActor(agentId), source: "no_skill_run_start" },
      { expectedStatuses: ["todo"] },
    );

    expect(result).toBeNull();
    const row = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(row).toMatchObject({ status: "blocked", assigneeAgentId: null });
  });

  it("writes a guarded update whose expected status still holds", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ status: "in_progress", assigneeAgentId: agentId });

    const result = await svc.update(
      issueId,
      { status: "in_review" },
      { actor: agentActor(agentId), source: "no_skill_completion" },
      { expectedStatuses: ["in_progress"] },
    );

    expect(result?.status).toBe("in_review");
  });

  it("writes no flag for an allowed move", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ assigneeAgentId: agentId });

    await svc.checkout(issueId, agentId, ["todo"], null);

    expect(await flagRows(issueId)).toHaveLength(0);
  });

  it("logs one row with from, to, actor and source when status changes", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue();
    const runId = await seedRun(agentId);

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "in_review", updatedAt: new Date() },
      context: { actor: agentActor(agentId, runId), source: "no_skill_completion" },
    });

    expect(result?.row.status).toBe("in_review");
    expect(result?.previousStatus).toBe("todo");
    const rows = await statusRows(issueId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      actorType: "agent",
      actorId: agentId,
      agentId,
      runId,
      entityType: "issue",
    });
    expect(rows[0].details).toMatchObject({
      status: "in_review",
      _previous: { status: "todo" },
      source: "no_skill_completion",
    });
  });

  it("keeps the transition when its log row cannot be written", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue();

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "in_review" },
      // No heartbeat_runs row: the activity insert trips its foreign key.
      context: { actor: agentActor(agentId, randomUUID()), source: "no_skill_completion" },
    });

    expect(result?.row.status).toBe("in_review");
    const row = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(row.status).toBe("in_review");
    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("writes no row when the status is unchanged", async () => {
    const issueId = await seedIssue({ status: "blocked" });

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "blocked", title: "Renamed" },
      context: { actor: { actorType: "system", actorId: "test" }, source: "unspecified" },
    });

    expect(result?.row.title).toBe("Renamed");
    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("writes no row when the caller logs the transition itself", async () => {
    const issueId = await seedIssue();

    await writeIssueStatus(db, {
      issueId,
      set: { status: "done" },
      context: { actor: { actorType: "system", actorId: "test" }, source: "issue_patch" },
      skipActivity: true,
    });

    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("still rejects an unknown status and leaves the row alone", async () => {
    const issueId = await seedIssue();

    await expect(
      writeIssueStatus(db, {
        issueId,
        set: { status: "not_a_status" },
        context: { actor: { actorType: "system", actorId: "test" }, source: "unspecified" },
      }),
    ).rejects.toThrow(/Unknown issue status/);

    const row = await db.select().from(issues).where(eq(issues.id, issueId)).then((rows) => rows[0]);
    expect(row.status).toBe("todo");
    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("keeps a guard that fails returning null, with no row written", async () => {
    const issueId = await seedIssue({ status: "done" });

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "in_progress" },
      where: eq(issues.status, "todo"),
      context: { actor: { actorType: "system", actorId: "test" }, source: "checkout" },
    });

    expect(result).toBeNull();
    expect(await statusRows(issueId)).toHaveLength(0);
  });

  it("logs checkout and release through the service", async () => {
    const agentId = await seedAgent();
    const issueId = await seedIssue({ assigneeAgentId: agentId });
    const runId = await seedRun(agentId);

    await svc.checkout(issueId, agentId, ["todo"], null);
    await svc.release(issueId, agentId, runId);

    const rows = await statusRows(issueId);
    const transitions = rows
      .map((row) => row.details as Record<string, any>)
      .map((details) => [details._previous.status, details.status, details.source]);
    expect(transitions).toEqual(
      expect.arrayContaining([
        ["todo", "in_progress", "checkout"],
        ["in_progress", "todo", "release"],
      ]),
    );
    expect(rows).toHaveLength(2);
  });

  it("logs a status update() was given, unless the caller says it logged it", async () => {
    const agentId = await seedAgent();
    const loggedHere = await seedIssue({ assigneeAgentId: agentId });
    const loggedByCaller = await seedIssue({ assigneeAgentId: agentId });

    await svc.update(loggedHere, { status: "in_progress" }, {
      actor: agentActor(agentId),
      source: "no_skill_run_start",
    });
    await svc.update(loggedByCaller, { status: "in_progress" }, {
      actor: agentActor(agentId),
      source: "issue_patch",
      statusLoggedByCaller: true,
    });

    expect(await statusRows(loggedHere)).toHaveLength(1);
    expect(await statusRows(loggedByCaller)).toHaveLength(0);
  });

  it("logs a status update() derives from a hold even when the caller logs its own row", async () => {
    const issueId = await seedIssue();

    const updated = await svc.update(
      issueId,
      {
        // An operator hold does not stand on `todo`, so update() parks the task.
        hold: {
          kind: "operator",
          blockers: [],
          note: "waiting",
          reheld: false,
          setAt: "2026-01-01T00:00:00.000Z",
          setByAgentId: null,
          setByUserId: "operator",
        },
      },
      { actor: { actorType: "user", actorId: "operator" }, source: "issue_patch", statusLoggedByCaller: true },
    );

    expect(updated?.status).toBe("blocked");
    const rows = await statusRows(issueId);
    expect(rows).toHaveLength(1);
    expect(rows[0].details).toMatchObject({ _previous: { status: "todo" }, status: "blocked" });
  });
});
