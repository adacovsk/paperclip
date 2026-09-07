import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
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

const mockLogActivity = vi.hoisted(() => vi.fn(async () => undefined));

vi.mock("../services/index.js", () => ({
  accessService: () => mockAccessService,
  agentService: () => ({ getById: vi.fn() }),
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
    status: "cancelled" as const,
    assigneeAgentId: null,
    assigneeUserId: null,
    createdByUserId: "local-operator",
    identifier: "PAP-1",
    title: "A cancelled issue someone wants off the board",
  };
}

/**
 * Issues are never hidden.
 *
 * `hiddenAt` is filtered out by every listing, activity and routine query, so a
 * hidden row is invisible to the pipeline sweeps and to anyone auditing the
 * board — it cannot be tracked, only stumbled upon. A terminal status says
 * "done with this" while staying greppable, which is what closing an issue is
 * for. The write path was removed rather than discouraged, because a filtered
 * row is exactly the kind of state that is only noticed long after it matters.
 */
describe("issues are never hidden", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIssueService.getById.mockResolvedValue(makeIssue());
    mockIssueService.update.mockImplementation(async (_id: string, patch: Record<string, unknown>) => ({
      ...makeIssue(),
      ...patch,
    }));
  });

  it("rejects a PATCH that tries to hide an issue, and writes nothing", async () => {
    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ hiddenAt: new Date().toISOString() });

    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/never hidden/i);
    // The rejection must come before any write: a caller that believes it hid
    // something, and a half-applied update, are both worse than a clean refusal.
    expect(mockIssueService.update).not.toHaveBeenCalled();
  });

  it("rejects an explicit hiddenAt: null too, rather than silently accepting it", async () => {
    // Un-hiding is also gone, because nothing can hide any more. Accepting the
    // field at all would keep the concept alive in callers.
    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ hiddenAt: null });

    expect(res.status).toBe(400);
    expect(mockIssueService.update).not.toHaveBeenCalled();
  });

  it("does not let hiddenAt ride along with an otherwise valid update", async () => {
    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "done", hiddenAt: new Date().toISOString() });

    expect(res.status).toBe(400);
    // Notably the status change is refused as well — the whole request fails,
    // so a caller cannot smuggle a hide past a legitimate-looking edit.
    expect(mockIssueService.update).not.toHaveBeenCalled();
  });

  it("still applies an ordinary update that carries no hiddenAt", async () => {
    const res = await request(createApp())
      .patch(`/api/issues/${ISSUE_ID}`)
      .send({ status: "done" });

    expect(res.status).toBe(200);
    expect(mockIssueService.update).toHaveBeenCalledWith(ISSUE_ID, { status: "done" });
  });

  it("keeps the hide affordances out of the UI and the CLI", () => {
    // The API guard above is the choke point — the UI button and the CLI flag
    // both went through it. These assertions stop either affordance being
    // rebuilt against an endpoint that now refuses it.
    const here = fileURLToPath(new URL(".", import.meta.url));
    const ui = readFileSync(`${here}/../../../ui/src/pages/IssueDetail.tsx`, "utf8");
    const cli = readFileSync(`${here}/../../../cli/src/commands/client/issue.ts`, "utf8");

    // The read-side banner survives on purpose: if a legacy row is hidden, the
    // detail page should say so rather than quietly render a normal issue.
    expect(ui).toContain("This issue is hidden");
    expect(ui).not.toMatch(/hiddenAt:\s*new Date\(\)/);
    expect(cli).not.toContain("--hidden-at");
    expect(cli).not.toContain("hiddenAt");
  });
});
