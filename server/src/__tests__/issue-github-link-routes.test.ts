import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

const mockIssueService = vi.hoisted(() => ({ getById: vi.fn(), getByIdentifier: vi.fn() }));
const mockLinkService = vi.hoisted(() => ({
  link: vi.fn(),
  linkOnCreate: vi.fn(),
  listForIssue: vi.fn(),
  unlink: vi.fn(),
  linkedTasks: vi.fn(),
}));
const mockLogActivity = vi.hoisted(() => vi.fn(async () => undefined));

vi.mock("../services/index.js", () => ({
  accessService: () => ({ canUser: vi.fn(), hasPermission: vi.fn() }),
  agentService: () => ({ getById: vi.fn() }),
  documentService: () => ({}),
  executionWorkspaceService: () => ({}),
  goalService: () => ({}),
  heartbeatService: () => ({}),
  issueApprovalService: () => ({}),
  issueService: () => mockIssueService,
  logActivity: mockLogActivity,
  projectService: () => ({}),
  routineService: () => ({}),
  workProductService: () => ({}),
}));
vi.mock("../services/issue-github-links.js", () => ({ issueGithubLinkService: () => mockLinkService }));

const ISSUE_ID = "11111111-1111-4111-8111-111111111111";
const LINK_ID = "22222222-2222-4222-8222-222222222222";

function createApp() {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = {
      type: "operator",
      userId: "local-operator",
      isMember: true,
      source: "local_implicit",
      isInstanceAdmin: false,
    };
    next();
  });
  app.use("/api", issueRoutes({} as any, {} as any));
  app.use(errorHandler);
  return app;
}

describe("GitHub issue links", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.getById.mockImplementation(async (id: string) =>
      id === ISSUE_ID ? { id, identifier: "AA-1" } : null,
    );
    mockLinkService.link.mockImplementation(async (issueId: string, refs: Array<Record<string, unknown>>) =>
      refs.map((r) => ({ id: LINK_ID, issueId, ...r })),
    );
  });

  it("links a task and logs it", async () => {
    const res = await request(createApp())
      .post(`/api/issues/${ISSUE_ID}/github-links`)
      .send({ repo: "owner/game", number: 7 });
    expect(res.status).toBe(201);
    expect(mockLinkService.link).toHaveBeenCalledWith(ISSUE_ID, [{ repo: "owner/game", number: 7 }], null);
    expect(mockLogActivity).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ action: "issue.github_linked", details: expect.objectContaining({ githubIssue: "owner/game#7" }) }),
    );
  });

  it("refuses a repo that is not owner/name and a number that is not one", async () => {
    for (const bad of [{ repo: "game", number: 7 }, { repo: "owner/game", number: 0 }, { repo: "owner/game", number: "7" }]) {
      const res = await request(createApp()).post(`/api/issues/${ISSUE_ID}/github-links`).send(bad);
      expect(res.status).toBe(400);
    }
    expect(mockLinkService.link).not.toHaveBeenCalled();
  });

  it("removes a link the task has, and 404s one it does not", async () => {
    mockLinkService.unlink.mockResolvedValueOnce({ id: LINK_ID, repo: "owner/game", number: 7 }).mockResolvedValueOnce(null);
    const ok = await request(createApp()).delete(`/api/issues/${ISSUE_ID}/github-links/${LINK_ID}`);
    expect(ok.status).toBe(200);
    const missing = await request(createApp()).delete(`/api/issues/${ISSUE_ID}/github-links/${LINK_ID}`);
    expect(missing.status).toBe(404);
  });

  it("looks up the tasks linked to a repository or one issue", async () => {
    mockLinkService.linkedTasks.mockResolvedValue([{ identifier: "AA-1", status: "done" }]);
    const all = await request(createApp()).get("/api/github-links").query({ repo: "owner/game" });
    expect(all.status).toBe(200);
    expect(mockLinkService.linkedTasks).toHaveBeenLastCalledWith("owner/game", undefined);
    const one = await request(createApp()).get("/api/github-links").query({ repo: "owner/game", number: "7" });
    expect(one.status).toBe(200);
    expect(mockLinkService.linkedTasks).toHaveBeenLastCalledWith("owner/game", 7);
  });

  it("refuses a lookup with no repo or a bad number", async () => {
    expect((await request(createApp()).get("/api/github-links")).status).toBe(422);
    expect((await request(createApp()).get("/api/github-links").query({ repo: "owner/game", number: "x" })).status).toBe(422);
  });
});
