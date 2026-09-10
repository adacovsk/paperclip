import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  agents,
  agentWakeupRequests,
  companies,
  createDb,
  heartbeatRuns,
  issues,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres stale-lock tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

/**
 * AA-6096: an issue holds a non-null `executionRunId` while `activeRun` is null,
 * and every assignment wake is silently a no-op.
 *
 * The shape that recurred is a lock held by a run that never leaves `queued`.
 * Nothing expired it: `reapOrphanedRuns` skips `queued` by design,
 * `releaseIssueExecutionAndPromote` only fires when a run *terminates*, and
 * `resumeQueuedRuns` runs only at server start. So the issue read as an ordinary
 * assigned `todo` while being permanently undispatchable — AA-5716 absorbed seven
 * dispatches over five days in exactly this state.
 */
describeEmbeddedPostgres("stale queued execution lock", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-stale-queued-lock-");
    db = createDb(tempDb.connectionString);
  }, 20_000);

  // No afterEach teardown: every fixture below is keyed on fresh UUIDs, so the
  // rows cannot collide across tests. Deleting them in dependency order means
  // chasing the whole FK graph (agent_runtime_state, company_skills, ...) for no
  // isolation benefit, and the embedded database is discarded in afterAll.

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  /**
   * Seeds an issue whose execution lock is held by a queued run belonging to a
   * *different* agent than the assignee — the AA-7277 shape, where a Coordinator
   * run was adopted as the lock for a Worker-assigned task.
   */
  async function seedLockedIssue(lockAgeMs: number) {
    const companyId = randomUUID();
    const holderAgentId = randomUUID();
    const assigneeAgentId = randomUUID();
    const runId = randomUUID();
    const issueId = randomUUID();
    const issuePrefix = `T${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`;
    const lockedAt = new Date(Date.now() - lockAgeMs);

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix,
      requireOperatorApprovalForNewAgents: false,
    });

    for (const [id, name] of [
      [holderAgentId, "Coordinator"],
      [assigneeAgentId, "Worker"],
    ] as const) {
      await db.insert(agents).values({
        id,
        companyId,
        name,
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      });
    }

    // The lock holder: queued, never started, and it never will be — in the wild
    // this is an agent that is paused or already at maxConcurrentRuns.
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId: holderAgentId,
      invocationSource: "assignment",
      triggerDetail: "system",
      status: "queued",
      contextSnapshot: { issueId },
      startedAt: null,
      createdAt: lockedAt,
      updatedAt: lockedAt,
    });

    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Locked out of dispatch by a queued run",
      status: "todo",
      priority: "medium",
      assigneeAgentId,
      executionRunId: runId,
      executionLockedAt: lockedAt,
      issueNumber: 1,
      identifier: `${issuePrefix}-1`,
    });

    return { companyId, assigneeAgentId, holderAgentId, runId, issueId };
  }

  async function readLock(issueId: string) {
    return db
      .select({ executionRunId: issues.executionRunId })
      .from(issues)
      .where(eq(issues.id, issueId))
      .then((rows) => rows[0] ?? null);
  }

  it("ages out a lock held by a long-queued run so the assignee can be dispatched", async () => {
    const { assigneeAgentId, issueId, runId: staleRunId } = await seedLockedIssue(60 * 60 * 1000);
    const heartbeat = heartbeatService(db);

    const result = await heartbeat.wakeup(assigneeAgentId, {
      source: "assignment",
      reason: "issue_assigned",
      payload: { issueId },
    });

    // Before the fix this returned a deferred wake and the lock was untouched.
    // Assert the lock actually MOVED off the stale run: merely non-null would
    // also pass if the stale run were cleared and then re-adopted by the
    // `legacyRun` fallback, which is the half of this fix that is easy to miss.
    expect(result?.kind).not.toBe("deferred");
    expect((await readLock(issueId))?.executionRunId).not.toBe(staleRunId);
  });

  it("leaves a freshly queued run holding the lock", async () => {
    // The complement: a queue that is merely busy must still serialize. Expiring
    // this one would double-dispatch work that is about to start.
    const { assigneeAgentId, issueId, runId } = await seedLockedIssue(5_000);
    const heartbeat = heartbeatService(db);

    await heartbeat.wakeup(assigneeAgentId, {
      source: "assignment",
      reason: "issue_assigned",
      payload: { issueId },
    });

    expect((await readLock(issueId))?.executionRunId).toBe(runId);
  });
});
