import { describe, expect, it } from "vitest";
import { detectClaudeUsageLimit } from "@paperclipai/adapter-claude-local/server";
import {
  USAGE_LIMIT_ERROR_CODE,
  USAGE_LIMIT_FALLBACK_BACKOFF_MS,
  activeUsageLimit,
  usageLimitFromResult,
} from "../services/usage-limit.js";

/**
 * A usage limit arrives as `subtype: success` with a non-zero exit, so nothing
 * distinguished it from a crash and every scheduler tick re-fired into it — 46
 * runs over ~17h, 35 of them one agent's cron. The three halves asserted here are
 * the ones that have to hold together: the adapter recognises the message and
 * resolves the reset instant, the server stores it, and a stored reset in the
 * future blocks while a past one does not.
 */

const WEEKLY = "You've hit your weekly limit · resets 8pm (America/Denver)";

function resultEvent(text: string) {
  return { type: "result", subtype: "success", result: text } as Record<string, unknown>;
}

describe("claude usage-limit detection", () => {
  it("recognises the weekly limit and resolves the reset instant in the stated zone", () => {
    const now = new Date("2026-09-17T18:00:00Z"); // 12:00 MDT
    const limit = detectClaudeUsageLimit({ parsed: resultEvent(WEEKLY), stdout: "", stderr: "", now });

    expect(limit.limited).toBe(true);
    expect(limit.scope).toBe("weekly");
    // 8pm MDT on the same day is 02:00Z the next day.
    expect(limit.resetAt).toBe("2026-09-18T02:00:00.000Z");
  });

  it("rolls to the next day when the reset hour has already passed today", () => {
    const now = new Date("2026-09-18T03:00:00Z"); // 21:00 MDT, past 8pm
    const limit = detectClaudeUsageLimit({ parsed: resultEvent(WEEKLY), stdout: "", stderr: "", now });

    expect(limit.resetAt).toBe("2026-09-19T02:00:00.000Z");
  });

  it("reports the limit without a reset instant when the text carries no time", () => {
    const limit = detectClaudeUsageLimit({
      parsed: resultEvent("You've hit your usage limit"),
      stdout: "",
      stderr: "",
    });

    expect(limit).toMatchObject({ limited: true, resetAt: null });
  });

  it("reads a limit reported only on stderr", () => {
    const limit = detectClaudeUsageLimit({ parsed: null, stdout: "", stderr: WEEKLY });
    expect(limit.limited).toBe(true);
  });

  it("does not fire on an ordinary failure", () => {
    const limit = detectClaudeUsageLimit({
      parsed: resultEvent("Error: ENOENT: no such file or directory"),
      stdout: "",
      stderr: "",
    });

    expect(limit.limited).toBe(false);
  });
});

describe("usage-limit state", () => {
  const now = new Date("2026-09-17T18:00:00Z");

  it("stores the adapter's reset instant against the run that observed it", () => {
    const state = usageLimitFromResult(
      {
        errorCode: USAGE_LIMIT_ERROR_CODE,
        errorMeta: { usageLimited: true, usageLimitScope: "weekly", usageLimitResetAt: "2026-09-18T02:00:00.000Z" },
      },
      { runId: "run-1", now },
    );

    expect(state).toMatchObject({ resetAt: "2026-09-18T02:00:00.000Z", scope: "weekly", runId: "run-1" });
  });

  it("falls back to a bounded window when no reset instant was parsed", () => {
    const state = usageLimitFromResult(
      { errorCode: USAGE_LIMIT_ERROR_CODE, errorMeta: { usageLimited: true } },
      { now },
    );

    expect(new Date(state!.resetAt).getTime()).toBe(now.getTime() + USAGE_LIMIT_FALLBACK_BACKOFF_MS);
  });

  it("ignores limit metadata on a run the adapter did not classify as limited", () => {
    const state = usageLimitFromResult(
      { errorCode: "adapter_failed", errorMeta: { usageLimitResetAt: "2099-01-01T00:00:00.000Z" } },
      { now },
    );

    expect(state).toBeNull();
  });

  it("blocks while the reset is in the future and lifts once it passes", () => {
    const stateJson = { usageLimit: { resetAt: "2026-09-18T02:00:00.000Z", scope: "weekly" } };

    expect(activeUsageLimit(stateJson, now)).toMatchObject({ scope: "weekly" });
    expect(activeUsageLimit(stateJson, new Date("2026-09-18T02:00:01Z"))).toBeNull();
  });

  it("treats an agent with no stored limit as unblocked", () => {
    expect(activeUsageLimit({}, now)).toBeNull();
    expect(activeUsageLimit(null, now)).toBeNull();
    expect(activeUsageLimit({ usageLimit: { resetAt: "not a date" } }, now)).toBeNull();
  });
});
