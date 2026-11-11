import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { skillRoutes } from "../routes/skills.js";
import { errorHandler } from "../middleware/index.js";

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

const mockAccessService = vi.hoisted(() => ({
  canUser: vi.fn(),
  hasPermission: vi.fn(),
}));

const mockSkillService = vi.hoisted(() => ({
  importFromSource: vi.fn(),
}));

const mockLogActivity = vi.hoisted(() => vi.fn());

vi.mock("../services/index.js", () => ({
  accessService: () => mockAccessService,
  agentService: () => mockAgentService,
  skillService: () => mockSkillService,
  logActivity: mockLogActivity,
}));

function createApp(actor: Record<string, unknown>) {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });
  app.use("/api", skillRoutes({} as any));
  app.use(errorHandler);
  return app;
}

describe("skill mutation permissions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSkillService.importFromSource.mockResolvedValue({
      imported: [],
      warnings: [],
    });
    mockLogActivity.mockResolvedValue(undefined);
    mockAccessService.canUser.mockResolvedValue(true);
    mockAccessService.hasPermission.mockResolvedValue(false);
  });

  it("allows local operator operators to mutate skills", async () => {
    const res = await request(createApp({
      type: "operator",
      userId: "local-operator",
      source: "local_implicit",
      isInstanceAdmin: false,
    }))
      .post("/api/skills/import")
      .send({ source: "https://github.com/vercel-labs/agent-browser" });

    expect(res.status, JSON.stringify(res.body)).toBe(201);
    expect(mockSkillService.importFromSource).toHaveBeenCalledWith(
      "https://github.com/vercel-labs/agent-browser",
    );
  });

  it("blocks agents without management permission from mutating skills", async () => {
    mockAgentService.getById.mockResolvedValue({
      id: "agent-1",
      permissions: {},
    });

    const res = await request(createApp({
      type: "agent",
      agentId: "agent-1",
      runId: "run-1",
    }))
      .post("/api/skills/import")
      .send({ source: "https://github.com/vercel-labs/agent-browser" });

    expect(res.status, JSON.stringify(res.body)).toBe(403);
    expect(mockSkillService.importFromSource).not.toHaveBeenCalled();
  });

  it("allows agents with canCreateAgents to mutate skills", async () => {
    mockAgentService.getById.mockResolvedValue({
      id: "agent-1",
      permissions: { canCreateAgents: true },
    });

    const res = await request(createApp({
      type: "agent",
      agentId: "agent-1",
      runId: "run-1",
    }))
      .post("/api/skills/import")
      .send({ source: "https://github.com/vercel-labs/agent-browser" });

    expect(res.status, JSON.stringify(res.body)).toBe(201);
    expect(mockSkillService.importFromSource).toHaveBeenCalledWith(
      "https://github.com/vercel-labs/agent-browser",
    );
  });
});
