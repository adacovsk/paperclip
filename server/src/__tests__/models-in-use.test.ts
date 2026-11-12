import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { agents, costEvents, createDb } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { labelForClaudeModel, modelsInUse } from "../services/models-in-use.ts";

describe("labelForClaudeModel", () => {
  it("names a Claude id, and shows any other shape as it is", () => {
    expect(labelForClaudeModel("claude-opus-5-5")).toBe("Claude Opus 5.5");
    expect(labelForClaudeModel("claude-sonnet-5")).toBe("Claude Sonnet 5");
    expect(labelForClaudeModel("claude-haiku-4-5-20251001")).toBe("Claude Haiku 4.5");
    expect(labelForClaudeModel("opus")).toBe("opus");
  });
});

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

describeEmbeddedPostgres("modelsInUse", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  const NOW = new Date("2026-11-11T12:00:00.000Z");
  const daysAgo = (n: number) => new Date(NOW.getTime() - n * 24 * 60 * 60 * 1000);

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-models-in-use-");
    db = createDb(tempDb.connectionString);
  }, 120_000);

  afterEach(async () => {
    await db.delete(costEvents);
    await db.delete(agents);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function agent(adapterType: string, model?: string) {
    const id = randomUUID();
    await db.insert(agents).values({
      id,
      name: `agent-${id.slice(0, 6)}`,
      role: "engineer",
      status: "idle",
      adapterType,
      adapterConfig: model ? { model } : {},
      runtimeConfig: {},
      permissions: {},
    });
    return id;
  }

  async function ran(agentId: string, model: string, at: Date) {
    await db.insert(costEvents).values({
      agentId,
      provider: "anthropic",
      biller: "anthropic",
      billingType: "subscription",
      model,
      inputTokens: 1,
      outputTokens: 1,
      costCents: 0,
      occurredAt: at,
    });
  }

  it("lists what agents ran in the window, most recent first, then what they are set to", async () => {
    const worker = await agent("claude_local", "claude-opus-5-5");
    const planner = await agent("claude_local", "claude-sonnet-5-5");
    await ran(worker, "claude-fable-5-2", daysAgo(2));
    await ran(worker, "claude-opus-5-5", daysAgo(0.1));
    await ran(planner, "claude-sonnet-5-5", daysAgo(1));
    await ran(planner, "claude-opus-4-8", daysAgo(60));

    const models = await modelsInUse(db, "claude_local", NOW);
    expect(models.map((m) => m.id)).toEqual(["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2"]);
    expect(models[0]).toEqual({ id: "claude-opus-5-5", label: "Claude Opus 5.5" });
  });

  it("includes a configured model no run has used yet, and nothing from another adapter", async () => {
    await agent("claude_local", "claude-haiku-5");
    const other = await agent("codex_local", "gpt-5");
    await ran(other, "gpt-5", daysAgo(1));

    expect((await modelsInUse(db, "claude_local", NOW)).map((m) => m.id)).toEqual(["claude-haiku-5"]);
  });

  it("is empty for an instance that has run nothing", async () => {
    expect(await modelsInUse(db, "claude_local", NOW)).toEqual([]);
  });
});
