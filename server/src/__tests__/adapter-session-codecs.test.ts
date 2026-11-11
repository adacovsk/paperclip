import { describe, expect, it } from "vitest";
import { sessionCodec as claudeSessionCodec } from "@paperclipai/adapter-claude-local/server";

describe("adapter session codecs", () => {
  it("normalizes claude session params with cwd", () => {
    const parsed = claudeSessionCodec.deserialize({
      session_id: "claude-session-1",
      folder: "/tmp/workspace",
    });
    expect(parsed).toEqual({
      sessionId: "claude-session-1",
      cwd: "/tmp/workspace",
    });

    const serialized = claudeSessionCodec.serialize(parsed);
    expect(serialized).toEqual({
      sessionId: "claude-session-1",
      cwd: "/tmp/workspace",
    });
    expect(claudeSessionCodec.getDisplayId?.(serialized ?? null)).toBe("claude-session-1");
  });
});
