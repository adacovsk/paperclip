import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { instanceProfileRoutes } from "../routes/instance-profile.js";
import { errorHandler } from "../middleware/index.js";

const mockInstanceProfileService = vi.hoisted(() => ({
  get: vi.fn(),
  update: vi.fn(),
  updateBranding: vi.fn(),
}));

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

const mockLogActivity = vi.hoisted(() => vi.fn());

vi.mock("../services/index.js", () => ({
  agentService: () => mockAgentService,
  instanceProfileService: () => mockInstanceProfileService,
  logActivity: mockLogActivity,
}));

function createProfile() {
  const now = new Date("2026-03-19T02:00:00.000Z");
  return {
    id: "instance-settings-1",
    pauseReason: null,
    pausedAt: null,
    name: "Paperclip",
    description: null,
    status: "active",
    issuePrefix: "PAP",
    issueCounter: 568,
    budgetMonthlyCents: 0,
    spentMonthlyCents: 0,
    requireOperatorApprovalForNewAgents: false,
    brandColor: "#123456",
    logoAssetId: "11111111-1111-4111-8111-111111111111",
    logoUrl: "/api/assets/11111111-1111-4111-8111-111111111111/content",
    createdAt: now,
    updatedAt: now,
  };
}

function createApp(actor: Record<string, unknown>) {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });
  app.use("/api", instanceProfileRoutes({} as any));
  app.use(errorHandler);
  return app;
}

describe("PATCH /api/instance/profile/branding", () => {
  beforeEach(() => {
    mockInstanceProfileService.updateBranding.mockReset();
    mockAgentService.getById.mockReset();
    mockLogActivity.mockReset();
  });

  it("rejects non-CEO agent callers", async () => {
    mockAgentService.getById.mockResolvedValue({
      id: "agent-1",
      role: "engineer",
    });
    const app = createApp({
      type: "agent",
      agentId: "agent-1",
      source: "agent_key",
      runId: "run-1",
    });

    const res = await request(app)
      .patch("/api/instance/profile/branding")
      .send({ logoAssetId: "11111111-1111-4111-8111-111111111111" });

    expect(res.status).toBe(403);
    expect(res.body.error).toContain("Only CEO agents");
    expect(mockInstanceProfileService.updateBranding).not.toHaveBeenCalled();
  });

  it("allows CEO agent callers to update branding fields", async () => {
    const profile = createProfile();
    mockAgentService.getById.mockResolvedValue({
      id: "agent-1",
      role: "ceo",
    });
    mockInstanceProfileService.updateBranding.mockResolvedValue(profile);
    const app = createApp({
      type: "agent",
      agentId: "agent-1",
      source: "agent_key",
      runId: "run-1",
    });

    const res = await request(app)
      .patch("/api/instance/profile/branding")
      .send({
        logoAssetId: "11111111-1111-4111-8111-111111111111",
        brandColor: "#123456",
      });

    expect(res.status).toBe(200);
    expect(res.body.logoAssetId).toBe(profile.logoAssetId);
    expect(mockInstanceProfileService.updateBranding).toHaveBeenCalledWith({
      logoAssetId: "11111111-1111-4111-8111-111111111111",
      brandColor: "#123456",
    });
    expect(mockLogActivity).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
          actorType: "agent",
        actorId: "agent-1",
        agentId: "agent-1",
        runId: "run-1",
        action: "instance.branding_updated",
        details: {
          logoAssetId: "11111111-1111-4111-8111-111111111111",
          brandColor: "#123456",
        },
      }),
    );
  });

  it("allows operator callers to update branding fields", async () => {
    const profile = createProfile();
    mockInstanceProfileService.updateBranding.mockResolvedValue({
      ...profile,
      brandColor: null,
      logoAssetId: null,
      logoUrl: null,
    });
    const app = createApp({
      type: "operator",
      userId: "user-1",
      source: "local_implicit",
    });

    const res = await request(app)
      .patch("/api/instance/profile/branding")
      .send({ brandColor: null, logoAssetId: null });

    expect(res.status).toBe(200);
    expect(res.body.brandColor).toBeNull();
    expect(res.body.logoAssetId).toBeNull();
  });

  it("rejects non-branding fields in the request body", async () => {
    const app = createApp({
      type: "operator",
      userId: "user-1",
      source: "local_implicit",
    });

    const res = await request(app)
      .patch("/api/instance/profile/branding")
      .send({
        logoAssetId: "11111111-1111-4111-8111-111111111111",
        status: "archived",
      });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe("Validation error");
    expect(mockInstanceProfileService.updateBranding).not.toHaveBeenCalled();
  });
});

describe("GET /api/instance/profile", () => {
  beforeEach(() => {
    mockInstanceProfileService.get.mockReset();
  });

  it("returns the profile to members", async () => {
    const profile = createProfile();
    mockInstanceProfileService.get.mockResolvedValue(profile);
    const app = createApp({ type: "operator", userId: "user-1", source: "session", isMember: true });

    const res = await request(app).get("/api/instance/profile");

    expect(res.status).toBe(200);
    expect(res.body.issuePrefix).toBe("PAP");
  });

  it("rejects operator sessions without a membership", async () => {
    const app = createApp({ type: "operator", userId: "user-2", source: "session", isMember: false });

    const res = await request(app).get("/api/instance/profile");

    expect(res.status).toBe(403);
    expect(mockInstanceProfileService.get).not.toHaveBeenCalled();
  });

  it("rejects unauthenticated callers", async () => {
    const app = createApp({ type: "none", source: "none" });

    const res = await request(app).get("/api/instance/profile");

    expect(res.status).toBe(401);
  });
});
