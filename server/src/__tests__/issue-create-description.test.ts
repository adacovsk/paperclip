import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

const mockIssueService = vi.hoisted(() => ({
  create: vi.fn(),
  getById: vi.fn(),
  getAncestors: vi.fn(),
  findMentionedProjectIds: vi.fn(),
  getCommentCursor: vi.fn(),
  getComment: vi.fn(),
}));

vi.mock("../services/index.js", () => ({
  accessService: () => ({ canUser: vi.fn(async () => true), hasPermission: vi.fn(async () => true) }),
  agentService: () => ({ getById: vi.fn(async () => ({ id: "agent-1", companyId: "company-1", role: "ceo", permissions: {} })) }),
  documentService: () => ({ getIssueDocumentPayload: vi.fn(async () => ({})) }),
  executionWorkspaceService: () => ({ getById: vi.fn() }),
  goalService: () => ({ getById: vi.fn(), getDefaultCompanyGoal: vi.fn() }),
  heartbeatService: () => ({ wakeup: vi.fn(async () => undefined), reportRunActivity: vi.fn(async () => undefined) }),
  issueApprovalService: () => ({}),
  issueService: () => mockIssueService,
  logActivity: vi.fn(async () => undefined),
  projectService: () => ({ getById: vi.fn(), listByIds: vi.fn() }),
  routineService: () => ({ syncRunStatusForIssue: vi.fn(async () => undefined) }),
  workProductService: () => ({ listForIssue: vi.fn(async () => []) }),
}));

function createApp(actor: Record<string, unknown>) {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });
  app.use("/api", issueRoutes({} as any, {} as any));
  app.use(errorHandler);
  return app;
}

const AGENT = { type: "agent", agentId: "agent-1", runId: "run-1", companyId: "company-1" };
const OPERATOR = {
  type: "operator",
  userId: "user-1",
  source: "session",
  isInstanceAdmin: true,
  companyIds: ["company-1"],
};

const BODY = "What: the loader drops the trait. Why: silently wrong at runtime. Done-when: a test covers it.";

describe("agent-filed issues must carry their own description", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.create.mockResolvedValue({ id: "issue-1", identifier: "AA-1", title: "t" });
  });

  it("rejects a title-only filing from an agent", async () => {
    // Regression: agents repeatedly filed bare titles while the real
    // What/Why/Where/Done-when sat in a comment on the task they were reviewing,
    // leaving Coordinator to rebuild the body by hand from a different issue.
    const res = await request(createApp(AGENT))
      .post("/api/companies/company-1/issues")
      .send({ title: "Loader drops the trait" });

    expect(res.status).toBe(422);
    expect(res.body.error).toMatch(/description/i);
    expect(mockIssueService.create).not.toHaveBeenCalled();
  });

  it("rejects a filing whose description is only whitespace", async () => {
    const res = await request(createApp(AGENT))
      .post("/api/companies/company-1/issues")
      .send({ title: "Loader drops the trait", description: "   \n  " });

    expect(res.status).toBe(422);
    expect(mockIssueService.create).not.toHaveBeenCalled();
  });

  it("accepts an agent filing that carries a real body", async () => {
    const res = await request(createApp(AGENT))
      .post("/api/companies/company-1/issues")
      .send({ title: "Loader drops the trait", description: BODY });

    expect(res.status).toBe(201);
    expect(mockIssueService.create).toHaveBeenCalledWith(
      "company-1",
      expect.objectContaining({ description: BODY, createdByAgentId: "agent-1" }),
    );
  });

  it("does not gate the operator — the UI legitimately creates title-only tasks", async () => {
    const res = await request(createApp(OPERATOR))
      .post("/api/companies/company-1/issues")
      .send({ title: "Quick note to self" });

    expect(res.status).toBe(201);
    expect(mockIssueService.create).toHaveBeenCalled();
  });
});
