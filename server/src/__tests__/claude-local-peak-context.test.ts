import { describe, expect, it } from "vitest";
import { parseClaudeStreamJson } from "@paperclipai/adapter-claude-local/server";

/**
 * Within-run context growth was invisible to every existing signal.
 *
 * `usage` reports run totals and session rotation is decided *between* runs from
 * the previous run's totals, so neither can see a session that starts under
 * every configured threshold and grows past the adapter's ceiling inside a
 * single run. That is the shape actually observed: 17.2M cached input tokens
 * with `sessionRotated: false`, terminating `adapter_failed`.
 *
 * `peakContextTokens` measures it. Nothing acts on it yet — a within-run kill
 * guard on a mis-set ceiling would end Worker runs mid-task, which is worse than
 * the failure it prevents while the failure is a sample of one.
 */
function assistantEvent(input: number, cacheRead: number, cacheCreate = 0): string {
  return JSON.stringify({
    type: "assistant",
    session_id: "s-1",
    message: {
      content: [{ type: "text", text: "working" }],
      usage: {
        input_tokens: input,
        cache_read_input_tokens: cacheRead,
        cache_creation_input_tokens: cacheCreate,
      },
    },
  });
}

const RESULT = JSON.stringify({
  type: "result",
  session_id: "s-1",
  result: "done",
  usage: { input_tokens: 4, cache_read_input_tokens: 120, output_tokens: 50 },
  total_cost_usd: 0.5,
});

describe("claude_local peak within-run context", () => {
  it("reports the largest single turn, not the last and not the sum", () => {
    const stdout = [
      assistantEvent(2, 1_000),
      assistantEvent(3, 900_000),   // the peak
      assistantEvent(1, 5_000),     // smaller again: a later turn must not lower it
      RESULT,
    ].join("\n");

    expect(parseClaudeStreamJson(stdout).peakContextTokens).toBe(900_003);
  });

  it("counts cache creation as context the turn had to carry", () => {
    const stdout = [assistantEvent(10, 20, 30), RESULT].join("\n");
    expect(parseClaudeStreamJson(stdout).peakContextTokens).toBe(60);
  });

  it("still reports a peak when the run produced no result event", () => {
    // The load-bearing case: a run killed or refused mid-stream emits no
    // `result`, so run totals are absent — and it is exactly the run whose size
    // needs accounting for.
    const stdout = [assistantEvent(2, 100), assistantEvent(2, 17_000_000)].join("\n");
    const parsed = parseClaudeStreamJson(stdout);

    expect(parsed.usage).toBeNull();
    expect(parsed.peakContextTokens).toBe(17_000_002);
  });

  it("is zero for a stream with no assistant turns", () => {
    expect(parseClaudeStreamJson(RESULT).peakContextTokens).toBe(0);
  });

  it("treats a turn with no usage block as zero rather than throwing", () => {
    const stdout = [
      JSON.stringify({ type: "assistant", message: { content: [] } }),
      assistantEvent(1, 41),
      RESULT,
    ].join("\n");
    expect(parseClaudeStreamJson(stdout).peakContextTokens).toBe(42);
  });
});
