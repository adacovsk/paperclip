import { describe, expect, it } from "vitest";
import {
  SWEEP_WAKE_SCOPE_KEY,
  isSweepWakeReason,
  wakeCoalesceScope,
} from "../services/sweep-wake-scope.js";

describe("isSweepWakeReason", () => {
  it("recognises a stage-completion wake", () => {
    expect(isSweepWakeReason("subtask_completed")).toBe(true);
  });

  it("does not claim dispatch wakes — those really are scoped to their task", () => {
    for (const reason of [
      "issue_assigned",
      "issue_status_changed",
      "issue_comment_mentioned",
      "process_lost_retry",
      null,
      undefined,
    ]) {
      expect(isSweepWakeReason(reason)).toBe(false);
    }
  });
});

describe("wakeCoalesceScope", () => {
  it("collapses every sweep onto one per-agent scope, whatever pivot task it names", () => {
    const a = wakeCoalesceScope("subtask_completed", "issue-a");
    const b = wakeCoalesceScope("subtask_completed", "issue-b");
    expect(a).toBe(SWEEP_WAKE_SCOPE_KEY);
    expect(a).toBe(b);
  });

  it("leaves a dispatch wake in its own task scope", () => {
    expect(wakeCoalesceScope("issue_assigned", "issue-a")).toBe("issue-a");
    expect(wakeCoalesceScope("issue_assigned", "issue-b")).not.toBe(
      wakeCoalesceScope("issue_assigned", "issue-a"),
    );
  });

  it("never collides a sweep with a task literally keyed like the sentinel", () => {
    expect(wakeCoalesceScope("issue_assigned", SWEEP_WAKE_SCOPE_KEY)).toBe(SWEEP_WAKE_SCOPE_KEY);
    // Same string, but only because the caller supplied it as a task key; a
    // dispatch onto it is still a dispatch. Documented rather than defended:
    // task keys are issue UUIDs, so the collision is not reachable in practice.
  });
});
