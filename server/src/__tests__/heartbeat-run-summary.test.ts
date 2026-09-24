import { describe, expect, it } from "vitest";
import { summarizeHeartbeatRunResultJson } from "../services/heartbeat-run-summary.js";

describe("summarizeHeartbeatRunResultJson", () => {
  it("truncates text fields and preserves cost aliases", () => {
    const summary = summarizeHeartbeatRunResultJson({
      summary: "a".repeat(600),
      result: "ok",
      message: "done",
      error: "failed",
      total_cost_usd: 1.23,
      cost_usd: 0.45,
      costUsd: 0.67,
      num_turns: 42,
      nested: { ignored: true },
    });

    expect(summary).toEqual({
      summary: "a".repeat(500),
      result: "ok",
      message: "done",
      error: "failed",
      total_cost_usd: 1.23,
      cost_usd: 0.45,
      costUsd: 0.67,
      num_turns: 42,
    });
  });

  it("keeps a turn count under either spelling", () => {
    expect(summarizeHeartbeatRunResultJson({ num_turns: 160 })).toEqual({ num_turns: 160 });
    expect(summarizeHeartbeatRunResultJson({ numTurns: 7 })).toEqual({ numTurns: 7 });
  });

  it("keeps a zero turn count rather than dropping it as falsy", () => {
    expect(summarizeHeartbeatRunResultJson({ num_turns: 0 })).toEqual({ num_turns: 0 });
  });

  it("returns null for non-object and irrelevant payloads", () => {
    expect(summarizeHeartbeatRunResultJson(null)).toBeNull();
    expect(summarizeHeartbeatRunResultJson(["nope"] as unknown as Record<string, unknown>)).toBeNull();
    expect(summarizeHeartbeatRunResultJson({ nested: { only: "ignored" } })).toBeNull();
  });
});
