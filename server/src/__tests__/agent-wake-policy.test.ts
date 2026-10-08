import { describe, expect, it } from "vitest";
import { agentMayWake } from "../services/agent-wake-policy.js";

describe("agentMayWake", () => {
  it("lets an agent wake itself", () => {
    expect(agentMayWake({ agentId: "a", role: "engineer" }, { id: "a", role: "engineer" })).toBe(true);
  });

  it("lets the Dispatcher wake the Coordinator", () => {
    expect(agentMayWake({ agentId: "d", role: "dispatcher" }, { id: "c", role: "coordinator" })).toBe(true);
  });

  it("does not let the Dispatcher wake anyone else", () => {
    expect(agentMayWake({ agentId: "d", role: "dispatcher" }, { id: "w", role: "engineer" })).toBe(false);
  });

  it("does not let other agents wake the Coordinator", () => {
    expect(agentMayWake({ agentId: "w", role: "engineer" }, { id: "c", role: "coordinator" })).toBe(false);
  });
});
