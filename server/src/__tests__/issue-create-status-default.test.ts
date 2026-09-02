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

const mockRoutineService = vi.hoisted(() => ({
  list: vi.fn(),
  syncRunStatusForIssue: vi.fn(async () => undefined),
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
  routineService: () => mockRoutineService,
  workProductService: () => ({ listForIssue: vi.fn(async () => []) }),
}));

function createApp() {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = OPERATOR;
    next();
  });
  app.use("/api", issueRoutes({} as any, {} as any));
  app.use(errorHandler);
  return app;
}

const OPERATOR = {
  type: "operator",
  userId: "user-1",
  source: "session",
  isInstanceAdmin: true,
  companyIds: ["company-1"],
};

const CRONLESS = "11111111-1111-4111-8111-111111111111";
const SCHEDULED = "22222222-2222-4222-8222-222222222222";

function routine(assigneeAgentId: string, triggers: Array<Record<string, unknown>>) {
  return { id: `routine-${assigneeAgentId}`, assigneeAgentId, status: "active", triggers };
}

const CRON_TRIGGER = { kind: "schedule", enabled: true, cronExpression: "15 20 * * *" };

async function createIssue(body: Record<string, unknown>) {
  return request(createApp()).post("/api/companies/company-1/issues").send({ title: "t", ...body });
}

function statusPassedToCreate() {
  return mockIssueService.create.mock.calls[0]?.[1]?.status;
}

describe("issue create resolves a reachable default status", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.create.mockResolvedValue({ id: "issue-1", identifier: "AA-1", title: "t" });
    mockRoutineService.list.mockResolvedValue([routine(SCHEDULED, [CRON_TRIGGER])]);
  });

  it("files an assigned task at todo when the assignee has no cron trigger", async () => {
    // The defect this covers: `backlog` is unreachable for an agent woken by
    // assignment, so such a task is undeliverable until someone promotes it by
    // hand. AA-5221 was itself filed that way.
    const res = await createIssue({ assigneeAgentId: CRONLESS });

    expect(res.status).toBe(201);
    expect(statusPassedToCreate()).toBe("todo");
  });

  it("keeps backlog when the assignee has an enabled cron trigger to dequeue it", async () => {
    const res = await createIssue({ assigneeAgentId: SCHEDULED });

    expect(res.status).toBe(201);
    expect(statusPassedToCreate()).toBe("backlog");
  });

  it("keeps backlog for an unassigned filing", async () => {
    const res = await createIssue({});

    expect(res.status).toBe(201);
    expect(statusPassedToCreate()).toBe("backlog");
    expect(mockRoutineService.list).not.toHaveBeenCalled();
  });

  it("honours an explicit status, backlog included", async () => {
    const res = await createIssue({ assigneeAgentId: CRONLESS, status: "backlog" });

    expect(res.status).toBe(201);
    expect(statusPassedToCreate()).toBe("backlog");
  });

  it("does not treat a disabled or non-schedule trigger as a dequeue path", async () => {
    mockRoutineService.list.mockResolvedValue([
      routine(CRONLESS, [
        { kind: "schedule", enabled: false, cronExpression: "15 20 * * *" },
        { kind: "webhook", enabled: true, cronExpression: null },
      ]),
    ]);

    const res = await createIssue({ assigneeAgentId: CRONLESS });

    expect(res.status).toBe(201);
    expect(statusPassedToCreate()).toBe("todo");
  });
});
