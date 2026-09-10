import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

const mockIssueService = vi.hoisted(() => ({
  getById: vi.fn(),
  update: vi.fn(),
  addComment: vi.fn(),
  findMentionedAgents: vi.fn(),
}));

const mockAccessService = vi.hoisted(() => ({
  canUser: vi.fn(),
  hasPermission: vi.fn(),
}));

const mockHeartbeatService = vi.hoisted(() => ({
  wakeup: vi.fn(async () => undefined),
  reportRunActivity: vi.fn(async () => undefined),
}));

const mockAgentService = vi.hoisted(() => ({ getById: vi.fn() }));
const mockLogActivity = vi.hoisted(() => vi.fn(async () => undefined));

vi.mock("../services/index.js", () => ({
  accessService: () => mockAccessService,
  agentService: () => mockAgentService,
  documentService: () => ({}),
  executionWorkspaceService: () => ({}),
  goalService: () => ({}),
  heartbeatService: () => mockHeartbeatService,
  issueApprovalService: () => ({}),
  issueService: () => mockIssueService,
  logActivity: mockLogActivity,
  projectService: () => ({}),
  routineService: () => ({ syncRunStatusForIssue: vi.fn(async () => undefined) }),
  workProductService: () => ({}),
}));

const ISSUE_ID = "11111111-1111-4111-8111-111111111111";

function createApp() {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = {
      type: "operator",
      userId: "local-operator",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: false,
    };
    next();
  });
  app.use("/api", issueRoutes({} as any, {} as any));
  app.use(errorHandler);
  return app;
}

function makeIssue() {
  return {
    id: ISSUE_ID,
    companyId: "company-1",
    status: "in_review" as const,
    assigneeAgentId: null,
    assigneeUserId: null,
    createdByUserId: "local-operator",
    identifier: "PAP-1",
    title: "Comment before status",
  };
}

/**
 * A status change and its reason are two writes that cannot be made one without
 * threading a transaction through both services. Which one runs first is
 * therefore a correctness decision, not an implementation detail: whichever
 * fails alone must leave a recoverable state.
 *
 * A comment with no status change is recoverable — the reason is on the task and
 * the caller can retry the status. A status change with no comment is not: it is
 * indistinguishable from a status flipped without work, which is the state every
 * completion gate exists to prevent. It was measured in the other order losing
 * the comment and keeping the status four times out of four.
 */
describe("PATCH /issues/:id writes the comment before the status", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.getById.mockResolvedValue(makeIssue());
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
    mockIssueService.addComment.mockResolvedValue({
      id: "comment-1",
      issueId: ISSUE_ID,
      companyId: "company-1",
      body: "why this moved",
      createdAt: new Date(),
      updatedAt: new Date(),
      authorAgentId: null,
      authorUserId: "local-operator",
    });
  });

  it("orders the comment insert ahead of the status update", async () => {
    const order: string[] = [];
    mockIssueService.addComment.mockImplementation(async () => {
      order.push("comment");
      return {
        id: "comment-1",
        issueId: ISSUE_ID,
        companyId: "company-1",
        body: "why this moved",
        createdAt: new Date(),
        updatedAt: new Date(),
        authorAgentId: null,
        authorUserId: "local-operator",
      };
    });
    mockIssueService.update.mockImplementation(async (_id: string, patch: Record<string, unknown>) => {
      order.push("status");
      return { ...makeIssue(), ...patch };
    });

    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "done", comment: "why this moved" });

    expect(res.status).toBe(200);
    expect(order).toEqual(["comment", "status"]);
  });

  it("does not advance the status when the comment write fails", async () => {
    mockIssueService.addComment.mockRejectedValue(new Error("comment insert rolled back"));
    mockIssueService.update.mockImplementation(async (_id: string, patch: Record<string, unknown>) => ({
      ...makeIssue(),
      ...patch,
    }));

    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "done", comment: "why this moved" });

    expect(res.status).toBeGreaterThanOrEqual(500);
    // The load-bearing assertion: the reason failed to record, so the status
    // must not have moved. The reverse is the silently-asymmetric failure.
    expect(mockIssueService.update).not.toHaveBeenCalled();
  });

  it("still updates the status when there is no comment to write", async () => {
    mockIssueService.update.mockImplementation(async (_id: string, patch: Record<string, unknown>) => ({
      ...makeIssue(),
      ...patch,
    }));

    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "done" });

    expect(res.status).toBe(200);
    expect(mockIssueService.addComment).not.toHaveBeenCalled();
    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, { status: "done" });
  });
});
