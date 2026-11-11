import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { createDb, issueBuilds, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueBuildService } from "../services/issue-builds.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres issue build tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("issue builds", () => {
  let db!: ReturnType<typeof createDb>;
  let builds!: ReturnType<typeof issueBuildService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issue-builds-");
    db = createDb(tempDb.connectionString);
    builds = issueBuildService(db);
  }, 120_000);

  afterEach(async () => {
    await db.delete(issueBuilds);
    await db.delete(issues);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function seedIssue() {
    const id = randomUUID();
    await db.insert(issues).values({ id, title: "task", status: "in_review", priority: "medium" });
    return id;
  }

  const result = (finishedAt: string, extra: Record<string, unknown> = {}) => ({
    exitCode: 1,
    lane: "local" as const,
    finishedAt,
    ...extra,
  });

  it("records a result with what its exit code means", async () => {
    const issueId = await seedIssue();
    const build = await builds.report(issueId, result("2026-11-11T10:00:00.000Z", { exitCode: 137, host: "box" }), null);
    expect(build).toMatchObject({ issueId, exitCode: 137, outcome: "fault", label: "Out of memory", host: "box" });
  });

  it("treats the same task and finish time as one result", async () => {
    const issueId = await seedIssue();
    const at = "2026-11-11T10:00:00.000Z";
    const first = await builds.report(issueId, result(at, { headSha: "c".repeat(40), action: "retry" }), null);
    const again = await builds.report(issueId, result(at, { action: "wake", note: "second strike" }), null);

    expect(again.id).toBe(first.id);
    // The later report says what was done next; it does not blank what the first one knew.
    expect(again).toMatchObject({ action: "wake", note: "second strike", headSha: "c".repeat(40) });
    expect(await builds.listForIssue(issueId)).toHaveLength(1);
  });

  it("lists a task's results newest first, and only its own", async () => {
    const issueId = await seedIssue();
    const other = await seedIssue();
    await builds.report(issueId, result("2026-11-11T10:00:00.000Z"), null);
    await builds.report(issueId, result("2026-11-11T12:00:00.000Z", { exitCode: 0, lane: "cloud" }), null);
    await builds.report(other, result("2026-11-11T11:00:00.000Z"), null);

    const listed = await builds.listForIssue(issueId);
    expect(listed.map((b) => [b.outcome, b.lane])).toEqual([
      ["green", "cloud"],
      ["red", "local"],
    ]);
  });

  it("names an exit code it has no entry for as a fault", async () => {
    const issueId = await seedIssue();
    const build = await builds.report(issueId, result("2026-11-11T10:00:00.000Z", { exitCode: 42 }), null);
    expect(build).toMatchObject({ outcome: "fault", label: "Exit 42" });
  });
});
