import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { IssueHold } from "@paperclipai/shared";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";
import { unprocessable } from "../errors.js";

const mockIssueService = vi.hoisted(() => ({
  getById: vi.fn(),
  update: vi.fn(),
  addComment: vi.fn(),
  findMentionedAgents: vi.fn(),
}));
const mockHoldService = vi.hoisted(() => ({
  fromInput: vi.fn(),
  fromComment: vi.fn(),
  backfillHolds: vi.fn(),
}));
const mockHeartbeatService = vi.hoisted(() => ({
  wakeup: vi.fn(async () => undefined),
  reportRunActivity: vi.fn(async () => undefined),
  cancelDetachedRunsForIssue: vi.fn(async () => []),
}));

vi.mock("../services/index.js", () => ({
  accessService: () => ({ canUser: vi.fn(), hasPermission: vi.fn() }),
  agentService: () => ({ getById: vi.fn() }),
  documentService: () => ({}),
  executionWorkspaceService: () => ({}),
  goalService: () => ({}),
  heartbeatService: () => mockHeartbeatService,
  issueApprovalService: () => ({}),
  issueService: () => mockIssueService,
  logActivity: vi.fn(async () => undefined),
  projectService: () => ({}),
  routineService: () => ({ syncRunStatusForIssue: vi.fn(async () => undefined) }),
  workProductService: () => ({}),
}));
vi.mock("../services/issue-holds.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../services/issue-holds.js")>()),
  issueHoldService: () => mockHoldService,
}));

const ISSUE_ID = "11111111-1111-4111-8111-111111111111";
const BLOCKER = { id: "22222222-2222-4222-8222-222222222222", identifier: "AA-7" };

function hold(overrides: Partial<IssueHold> = {}): IssueHold {
  return {
    kind: "until_merge",
    blockers: [BLOCKER],
    note: null,
    reheld: false,
    setAt: "2026-01-01T00:00:00.000Z",
    setByAgentId: null,
    setByUserId: "local-operator",
    ...overrides,
  };
}

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

function setIssue(status: string, assigneeAgentId: string | null = null) {
  const issue = {
    id: ISSUE_ID,
    status,
    assigneeAgentId,
    assigneeUserId: null,
    createdByUserId: "local-operator",
    identifier: "AA-1",
    title: "Held task",
    hold: null,
    releasedHold: null,
  };
  mockIssueService.getById.mockResolvedValue(issue);
  mockIssueService.update.mockImplementation(async (_id: string, patch: Record<string, unknown>) => ({
    ...issue,
    ...patch,
  }));
  return issue;
}

describe("holds on PATCH /issues/:id", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
    mockIssueService.addComment.mockImplementation(async (_id: string, body: string) => ({
      id: "comment-1",
      issueId: ISSUE_ID,
      body,
      createdAt: new Date(),
      updatedAt: new Date(),
      authorAgentId: null,
      authorUserId: "local-operator",
    }));
  });

  it("writes the Held: line itself when a hold arrives with no comment", async () => {
    setIssue("backlog");
    mockHoldService.fromInput.mockResolvedValue(hold());

    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ hold: { kind: "until_merge", blockers: ["AA-7"] } });

    expect(res.status).toBe(200);
    expect(mockIssueService.addComment).toHaveBeenCalledWith(ISSUE_ID, "Held: until AA-7 merges", expect.anything());
    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, { hold: hold() }, expect.objectContaining({ source: "issue_patch", statusLoggedByCaller: true }));
  });

  it("leaves no comment behind when the hold is refused", async () => {
    setIssue("backlog");
    mockHoldService.fromInput.mockRejectedValue(unprocessable("Hold names a task that does not exist: AA-9"));

    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ hold: { kind: "until_merge", blockers: ["AA-9"] }, comment: "Held: until AA-9 merges" });

    expect(res.status).toBe(422);
    expect(mockIssueService.addComment).not.toHaveBeenCalled();
    expect(mockIssueService.update).not.toHaveBeenCalled();
  });

  it("refuses a hold whose kind names no blockers before reaching any service", async () => {
    setIssue("backlog");
    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ hold: { kind: "until_pr" } });
    expect(res.status).toBe(400);
    expect(mockHoldService.fromInput).not.toHaveBeenCalled();
  });

  it("follows a Held: comment written beside status blocked", async () => {
    setIssue("in_review");
    mockHoldService.fromComment.mockResolvedValue(hold());

    await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "blocked", assigneeAgentId: null, comment: "Held: until AA-7 merges" });

    expect(mockIssueService.update).toHaveBeenCalledWith(
      ISSUE_ID,
      expect.objectContaining({ status: "blocked", hold: hold() }),
      expect.objectContaining({ source: "issue_patch", statusLoggedByCaller: true }),
    );
  });

  it("does not move a task for a Held: comment alone", async () => {
    setIssue("in_review");
    mockHoldService.fromComment.mockResolvedValue(hold());

    await request(createApp()).patch(`/api/issues/${ISSUE_ID}`).send({ comment: "Held: until AA-7 merges" });

    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, {}, expect.objectContaining({ source: "issue_patch", statusLoggedByCaller: true }));
  });

  it("does not record a hold from a comment on a blocked task that keeps its assignee", async () => {
    setIssue("blocked", "33333333-3333-4333-8333-333333333333");
    mockHoldService.fromComment.mockResolvedValue(hold({ kind: "operator", blockers: [] }));

    await request(createApp()).patch(`/api/issues/${ISSUE_ID}`).send({ comment: "Held: operator" });

    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, {}, expect.objectContaining({ source: "issue_patch", statusLoggedByCaller: true }));
  });
});

describe("holds on POST /issues/:id/comments", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
    mockIssueService.addComment.mockResolvedValue({
      id: "comment-1",
      issueId: ISSUE_ID,
      body: "Held: until AA-7 merges",
      createdAt: new Date(),
      updatedAt: new Date(),
      authorAgentId: null,
      authorUserId: "local-operator",
    });
  });

  it("records a hold restated as a comment on a parked task", async () => {
    setIssue("blocked");
    mockHoldService.fromComment.mockResolvedValue(hold());

    const res = await request(createApp())
      .post(`/api/issues/${ISSUE_ID}/comments`)
      .send({ body: "Held: until AA-7 merges" });

    expect(res.status).toBe(201);
    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, { hold: hold() }, expect.objectContaining({ source: "hold_comment" }));
  });

  it("leaves a task that is not parked alone", async () => {
    setIssue("in_progress", "33333333-3333-4333-8333-333333333333");
    mockHoldService.fromComment.mockResolvedValue(hold());

    await request(createApp()).post(`/api/issues/${ISSUE_ID}/comments`).send({ body: "Held: until AA-7 merges" });

    expect(mockIssueService.update).not.toHaveBeenCalled();
  });
});
