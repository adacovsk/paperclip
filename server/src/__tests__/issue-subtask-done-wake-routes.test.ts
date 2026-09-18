import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { issueRoutes } from "../routes/issues.js";
import { errorHandler } from "../middleware/index.js";

/**
 * The REST arm of the subtask-completion wake.
 *
 * The run executor runs this decision through `resolveSubtaskWakeTarget`; this
 * path did not, so any child reaching `done` woke `parent.assigneeAgentId`
 * unconditionally — including a parent parked at `in_review` with no live stage,
 * whose assignee cannot PATCH itself out and can only re-read its branch and
 * exit. Both arms are asserted here because a gate on one path only is what
 * produced the no-op runs.
 */

const PARENT_ID = "11111111-1111-4111-8111-111111111111";
const CHILD_ID = "22222222-2222-4222-8222-222222222222";
const WORKER_ID = "33333333-3333-4333-8333-333333333333";
const COORDINATOR_ID = "44444444-4444-4444-8444-444444444444";

const mockIssueService = vi.hoisted(() => ({
  getById: vi.fn(),
  update: vi.fn(),
  hasOpenChildExcept: vi.fn(),
  findMentionedAgents: vi.fn(),
}));

const mockAccessService = vi.hoisted(() => ({
  canUser: vi.fn(),
  hasPermission: vi.fn(),
}));

const mockHeartbeatService = vi.hoisted(() => ({
  wakeup: vi.fn(async () => undefined),
  reportRunActivity: vi.fn(async () => undefined),
  cancelDetachedRunsForIssue: vi.fn(async () => []),
}));

const mockCoordinatorIdFor = vi.hoisted(() => vi.fn(async () => COORDINATOR_ID as string | null));

vi.mock("../services/coordinator-lookup.js", () => ({
  coordinatorIdFor: mockCoordinatorIdFor,
}));

vi.mock("../services/index.js", () => ({
  accessService: () => mockAccessService,
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

function child(status: "todo" | "done") {
  return {
    id: CHILD_ID,
    companyId: "company-1",
    parentId: PARENT_ID,
    status,
    assigneeAgentId: null,
    assigneeUserId: null,
    identifier: "PAP-901",
    title: "Verify: parent",
  };
}

function parent(status: "todo" | "in_review" | "done") {
  return {
    id: PARENT_ID,
    companyId: "company-1",
    parentId: null,
    status,
    assigneeAgentId: WORKER_ID,
    assigneeUserId: null,
    identifier: "PAP-900",
    title: "Parent task",
  };
}

/** The wake dispatch runs detached from the response, so let its turn land. */
async function flushWakes() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}

async function markChildDone(parentStatus: "todo" | "in_review" | "done", hasOtherOpenChild: boolean) {
  mockIssueService.getById.mockImplementation(async (id: string) =>
    id === PARENT_ID ? parent(parentStatus) : child("todo"),
  );
  mockIssueService.update.mockImplementation(async () => child("done"));
  mockIssueService.hasOpenChildExcept.mockResolvedValue(hasOtherOpenChild);

  const res = await request(createApp()).patch(`/api/issues/${CHILD_ID}`).send({ status: "done" });
  expect(res.status).toBe(200);
  await flushWakes();
  return mockHeartbeatService.wakeup.mock.calls;
}

describe("subtask-completion wake on the REST path", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCoordinatorIdFor.mockResolvedValue(COORDINATOR_ID);
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
  });

  it("wakes the parent assignee while the parent's own stage is live", async () => {
    const calls = await markChildDone("todo", false);
    expect(calls.map(([agentId]) => agentId)).toEqual([WORKER_ID]);
    expect(calls[0][1]).toMatchObject({ reason: "subtask_completed", payload: { issueId: PARENT_ID } });
  });

  it("redirects to the Coordinator when the parent is in_review with no other open child", async () => {
    const calls = await markChildDone("in_review", false);
    expect(calls.map(([agentId]) => agentId)).toEqual([COORDINATOR_ID]);
    expect(calls[0][1]).toMatchObject({ reason: "subtask_completed", payload: { issueId: PARENT_ID } });
  });

  it("still wakes the parent assignee when another child of it is open", async () => {
    const calls = await markChildDone("in_review", true);
    expect(calls.map(([agentId]) => agentId)).toEqual([WORKER_ID]);
  });

  it("wakes nobody when the parent is already done", async () => {
    const calls = await markChildDone("done", false);
    expect(calls).toHaveLength(0);
  });
});
