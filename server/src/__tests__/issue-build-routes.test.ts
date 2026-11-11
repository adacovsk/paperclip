import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

const mockIssueService = vi.hoisted(() => ({ getById: vi.fn(), getByIdentifier: vi.fn() }));
const mockBuildService = vi.hoisted(() => ({ report: vi.fn(), listForIssue: vi.fn() }));
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
vi.mock("../services/issue-builds.js", () => ({ issueBuildService: () => mockBuildService }));

const ISSUE_ID = "11111111-1111-4111-8111-111111111111";
const STAGE_ID = "22222222-2222-4222-8222-222222222222";

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

const body = { exitCode: 0, lane: "cloud", finishedAt: "2026-11-11T10:00:00.000Z" };

describe("build results on /issues/:id/builds", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.getById.mockImplementation(async (id: string) =>
      id === ISSUE_ID || id === STAGE_ID ? { id, identifier: "AA-1" } : null,
    );
    mockBuildService.report.mockImplementation(async (issueId: string, input: Record<string, unknown>) => ({
      id: "build-1",
      issueId,
      outcome: "green",
      label: "Green",
      action: null,
      ...input,
    }));
  });

  it("records a result and logs it", async () => {
    const res = await request(createApp())
      .post(`/api/issues/${ISSUE_ID}/builds`)
      .send({ ...body, stageIssueId: STAGE_ID, headSha: "c".repeat(40) });

    expect(res.status).toBe(201);
    expect(mockBuildService.report).toHaveBeenCalledWith(
      ISSUE_ID,
      expect.objectContaining({ exitCode: 0, lane: "cloud", stageIssueId: STAGE_ID }),
      null,
    );
    expect(mockLogActivity).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ action: "issue.build_reported", entityId: ISSUE_ID }),
    );
  });

  it("refuses a lane, a commit id or a finish time that is not one", async () => {
    for (const bad of [{ lane: "moon" }, { headSha: "not-a-sha" }, { finishedAt: "yesterday" }, { exitCode: 999 }]) {
      const res = await request(createApp()).post(`/api/issues/${ISSUE_ID}/builds`).send({ ...body, ...bad });
      expect(res.status).toBe(400);
    }
    expect(mockBuildService.report).not.toHaveBeenCalled();
  });

  it("refuses a stage that does not exist, and a task that does not exist", async () => {
    const noStage = await request(createApp())
      .post(`/api/issues/${ISSUE_ID}/builds`)
      .send({ ...body, stageIssueId: "33333333-3333-4333-8333-333333333333" });
    expect(noStage.status).toBe(422);

    const noTask = await request(createApp())
      .post("/api/issues/44444444-4444-4444-8444-444444444444/builds")
      .send(body);
    expect(noTask.status).toBe(404);
    expect(mockBuildService.report).not.toHaveBeenCalled();
  });

  it("lists a task's results", async () => {
    mockBuildService.listForIssue.mockResolvedValue([{ id: "build-1" }]);
    const res = await request(createApp()).get(`/api/issues/${ISSUE_ID}/builds`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual([{ id: "build-1" }]);
  });
});
