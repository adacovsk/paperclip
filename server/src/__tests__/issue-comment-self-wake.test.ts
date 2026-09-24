import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

const ISSUE_ID = "11111111-1111-4111-8111-111111111111";
const ASSIGNEE_ID = "22222222-2222-4222-8222-222222222222";
const RUN_ID = "44444444-4444-4444-8444-444444444444";

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
  getRun: vi.fn(async () => null as { agentId: string } | null),
}));

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

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
  routineService: () => ({
    syncRunStatusForIssue: vi.fn(async () => undefined),
  }),
  workProductService: () => ({}),
}));

/**
 * `local_trusted` attributes every unauthenticated loopback call to the operator,
 * so an agent's own comment arrives with no agentId. Only the run id distinguishes
 * it from a comment the operator actually wrote.
 */
function createApp(runId?: string) {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = {
      type: "operator",
      userId: "local-operator",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
      ...(runId ? { runId } : {}),
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
    status: "todo" as const,
    assigneeAgentId: ASSIGNEE_ID,
    assigneeUserId: null,
    createdByUserId: "local-operator",
    identifier: "PAP-581",
    title: "Self-wake guard",
  };
}

async function postComment(app: express.Express) {
  return request(app).post(`/api/issues/${ISSUE_ID}/comments`).send({ body: "fire summary" });
}

// The wakeup enqueue runs detached from the request, so let its microtasks drain.
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("issue comment self-wake guard", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.getById.mockResolvedValue(makeIssue());
    mockIssueService.addComment.mockResolvedValue({
      id: "comment-1",
      issueId: ISSUE_ID,
      companyId: "company-1",
      body: "fire summary",
      createdAt: new Date(),
      updatedAt: new Date(),
      authorAgentId: null,
      authorUserId: "local-operator",
    });
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
    mockHeartbeatService.getRun.mockResolvedValue(null);
  });

  it("does not wake the assignee for a comment carrying that agent's own run id", async () => {
    mockHeartbeatService.getRun.mockResolvedValue({ agentId: ASSIGNEE_ID });

    const res = await postComment(createApp(RUN_ID));
    await flush();

    expect(res.status).toBe(201);
    expect(mockHeartbeatService.getRun).toHaveBeenCalledWith(RUN_ID);
    expect(mockHeartbeatService.wakeup).not.toHaveBeenCalled();
  });

  it("wakes the assignee for a comment carrying another agent's run id", async () => {
    mockHeartbeatService.getRun.mockResolvedValue({ agentId: "33333333-3333-4333-8333-333333333333" });

    await postComment(createApp(RUN_ID));
    await flush();

    expect(mockHeartbeatService.wakeup).toHaveBeenCalledWith(ASSIGNEE_ID, expect.anything());
  });

  it("wakes the assignee for an operator comment with no run id", async () => {
    await postComment(createApp());
    await flush();

    expect(mockHeartbeatService.getRun).not.toHaveBeenCalled();
    expect(mockHeartbeatService.wakeup).toHaveBeenCalledWith(ASSIGNEE_ID, expect.anything());
  });

  it("still wakes the assignee when the run lookup fails", async () => {
    mockHeartbeatService.getRun.mockRejectedValue(new Error("run lookup exploded"));

    await postComment(createApp(RUN_ID));
    await flush();

    expect(mockHeartbeatService.wakeup).toHaveBeenCalledWith(ASSIGNEE_ID, expect.anything());
  });
});
