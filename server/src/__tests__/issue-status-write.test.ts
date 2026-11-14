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

  function flagRows(issueId: string) {
    return db
      .select()
      .from(activityLog)
      .where(eq(activityLog.entityId, issueId))
      .then((rows) => rows.filter((row) => row.action === ISSUE_STATUS_TRANSITION_FLAGGED_ACTION));
  }

  it("lets a flagged move through and records the flag as the system", async () => {
    const agentId = await seedAgent();
    const runId = await seedRun(agentId);
    const issueId = await seedIssue({ status: "cancelled" });

    const result = await writeIssueStatus(db, {
      issueId,
      set: { status: "done" },
      context: { actor: agentActor(agentId, runId), source: "issue_patch" },
    });

    expect(result?.row.status).toBe("done");
    const flags = await flagRows(issueId);
    expect(flags).toHaveLength(1);
    expect(flags[0]).toMatchObject({ actorType: "system", actorId: "issue_status_table", agentId: null, runId: null });
    expect(flags[0].details).toMatchObject({
      status: "done",
      _previous: { status: "cancelled" },
      source: "issue_patch",
      flags: ["rejected"],
      actor: { actorType: "agent", actorId: agentId, runId },
    });
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
