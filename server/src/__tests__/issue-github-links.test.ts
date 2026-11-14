import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { createDb, issueGithubLinks, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { issueGithubLinkService } from "../services/issue-github-links.ts";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres GitHub link tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

const REPO = "owner/game";

describeEmbeddedPostgres("issue GitHub links", () => {
  let db!: ReturnType<typeof createDb>;
  let links!: ReturnType<typeof issueGithubLinkService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issue-github-links-");
    db = createDb(tempDb.connectionString);
    links = issueGithubLinkService(db);
  }, 120_000);

  afterEach(async () => {
    await db.delete(issueGithubLinks);
    await db.delete(issues);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function seedIssue(extra: Partial<typeof issues.$inferInsert> = {}) {
    const id = randomUUID();
    await db.insert(issues).values({ id, title: "task", status: "todo", priority: "medium", ...extra });
    return id;
  }

  it("links an issue once however often it is sent", async () => {
    const id = await seedIssue();
    await links.link(id, [{ repo: REPO, number: 7 }], null);
    const again = await links.link(id, [{ repo: REPO, number: 7 }, { repo: REPO, number: 9 }], null);
    expect(again.map((l) => l.number)).toEqual([7, 9]);
  });

  it("gives a new stage its parent's links plus its own", async () => {
    const parent = await seedIssue();
    await links.link(parent, [{ repo: REPO, number: 7 }], null);
    const child = await seedIssue({ parentId: parent });
    const linked = await links.linkOnCreate(child, parent, [{ repo: REPO, number: 7 }, { repo: REPO, number: 8 }], null);
    expect(linked.map((l) => l.number)).toEqual([7, 8]);
  });

  it("links nothing for a task with no parent and no issues", async () => {
    const id = await seedIssue();
    expect(await links.linkOnCreate(id, null, [], null)).toEqual([]);
  });

  it("answers which tasks an issue is waiting on, with their status", async () => {
    const done = await seedIssue({ status: "done", identifier: "AA-1" });
    const live = await seedIssue({ status: "in_progress", identifier: "AA-2" });
    await links.link(done, [{ repo: REPO, number: 7 }], null);
    await links.link(live, [{ repo: REPO, number: 7 }, { repo: "owner/other", number: 7 }], null);

    const forIssue = await links.linkedTasks(REPO, 7);
    expect(forIssue.map((t) => [t.identifier, t.status])).toEqual([["AA-1", "done"], ["AA-2", "in_progress"]]);
    expect((await links.linkedTasks(REPO)).length).toBe(2);
    expect((await links.linkedTasks("owner/other")).map((t) => t.identifier)).toEqual(["AA-2"]);
  });

  it("removes only a link the task has", async () => {
    const a = await seedIssue();
    const b = await seedIssue();
    const [link] = await links.link(a, [{ repo: REPO, number: 7 }], null);
    expect(await links.unlink(b, link!.id)).toBeNull();
    expect((await links.unlink(a, link!.id))?.number).toBe(7);
    expect(await links.listForIssue(a)).toEqual([]);
  });

  it("drops a task's links with the task", async () => {
    const id = await seedIssue();
    await links.link(id, [{ repo: REPO, number: 7 }], null);
    await db.delete(issues);
    expect(await links.linkedTasks(REPO)).toEqual([]);
  });
});
