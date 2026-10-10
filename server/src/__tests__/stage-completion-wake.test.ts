import { describe, expect, it } from "vitest";
import { resolveNoSkillCompletionStatus } from "../services/no-skill-completion-status.js";
import {
  branchAdvancedDuringRun,
  parseLsRemoteHead,
  shouldWakeNextMover,
} from "../services/stage-completion-wake.js";

describe("shouldWakeNextMover", () => {
  it("wakes on any status transition the run produced", () => {
    for (const nextStatus of ["done", "in_review"] as const) {
      for (const currentStatus of ["todo", "in_progress", "in_review", "blocked", "backlog"]) {
        expect(shouldWakeNextMover({ currentStatus, nextStatus, branchAdvanced: null, escalated: false })).toBe(true);
      }
    }
  });

  it("wakes a task already parked at the stage boundary even with no transition", () => {
    // A verify or a re-dispatched stage finishing at `in_review` moves work onto
    // the branch without moving the status. That is still a completion the next
    // mover owes an action on.
    expect(shouldWakeNextMover({ currentStatus: "in_review", nextStatus: null, branchAdvanced: true, escalated: false })).toBe(true);
  });

  it("suppresses the wake when nothing advanced and the status says nothing should", () => {
    for (const currentStatus of ["blocked", "backlog", "cancelled", "done"]) {
      expect(shouldWakeNextMover({ currentStatus, nextStatus: null, branchAdvanced: null, escalated: false })).toBe(false);
    }
  });

  it("never suppresses a wake for a status the completion gate would have promoted", () => {
    // The two functions must agree: anything `resolveNoSkillCompletionStatus`
    // treats as in-flight has a next mover, so a promotion can never be paired
    // with a suppressed wake. This is the coupling that made the unconditional
    // wake look safe — assert it instead of relying on it.
    for (const currentStatus of [
      "todo",
      "in_progress",
      "in_review",
      "blocked",
      "backlog",
      "cancelled",
      "done",
    ]) {
      for (const branchMerged of [true, false]) {
        const nextStatus = resolveNoSkillCompletionStatus({
          currentStatus,
          branchOnOrigin: true,
          branchMerged,
        });
        if (nextStatus !== null) {
          expect(shouldWakeNextMover({ currentStatus, nextStatus, branchAdvanced: null, escalated: false })).toBe(true);
        }
      }
    }
  });

  it("suppresses exactly the exits the executor logs as having advanced nothing", () => {
    // The executor's "a no-skill exit 0 is not evidence it should advance" log
    // fires when the gate declined AND the status is not already `in_review`.
    // The wake suppression must cover the same set, no more and no less — the
    // defect was that one branch established nothing advanced and the next woke
    // the Coordinator anyway.
    for (const currentStatus of [
      "todo",
      "in_progress",
      "in_review",
      "blocked",
      "backlog",
      "cancelled",
      "done",
    ]) {
      const nextStatus = resolveNoSkillCompletionStatus({
        currentStatus,
        branchOnOrigin: true,
        branchMerged: false,
      });
      const executorLoggedNoAdvance = nextStatus === null && currentStatus !== "in_review";
      expect(shouldWakeNextMover({ currentStatus, nextStatus, branchAdvanced: null, escalated: false })).toBe(!executorLoggedNoAdvance);
    }
  });
});

describe("shouldWakeNextMover on a re-dispatched in_review stage", () => {
  const base = { currentStatus: "in_review", nextStatus: null } as const;

  it("suppresses the wake when the run left the branch on origin where it found it", () => {
    // A verify that offloaded its build, or re-launched one because the base
    // moved, and will be woken again when it finishes. The Verify never left
    // in_review and nothing new reached origin, so the parent's next mover has
    // nothing to read.
    expect(shouldWakeNextMover({ ...base, branchAdvanced: false, escalated: false })).toBe(false);
  });

  it("wakes when the run moved the branch on origin", () => {
    // Landing pushes the branch: the re-verify passed and the PR is open.
    expect(shouldWakeNextMover({ ...base, branchAdvanced: true, escalated: false })).toBe(true);
  });

  it("keeps the wake when the branch could not be read", () => {
    expect(shouldWakeNextMover({ ...base, branchAdvanced: null, escalated: false })).toBe(true);
  });

  it("wakes on an escalation even though the branch did not move", () => {
    // The run report blocked the task; that status change is the advance.
    expect(shouldWakeNextMover({ ...base, branchAdvanced: false, escalated: true })).toBe(true);
  });

  it("does not consult the branch for a run that transitioned the status", () => {
    for (const nextStatus of ["done", "in_review"] as const) {
      expect(shouldWakeNextMover({ currentStatus: "in_progress", nextStatus, branchAdvanced: false, escalated: false })).toBe(
        true,
      );
    }
  });
});

describe("branchAdvancedDuringRun", () => {
  it("compares the two heads", () => {
    expect(branchAdvancedDuringRun({ sha: "aaa" }, { sha: "aaa" })).toBe(false);
    expect(branchAdvancedDuringRun({ sha: "aaa" }, { sha: "bbb" })).toBe(true);
  });

  it("counts the first push of a branch as an advance", () => {
    expect(branchAdvancedDuringRun({ sha: null }, { sha: "bbb" })).toBe(true);
    expect(branchAdvancedDuringRun({ sha: null }, { sha: null })).toBe(false);
  });

  it("answers unknown when either reading failed", () => {
    expect(branchAdvancedDuringRun(null, { sha: "aaa" })).toBeNull();
    expect(branchAdvancedDuringRun({ sha: "aaa" }, null)).toBeNull();
  });
});

describe("parseLsRemoteHead", () => {
  it("returns the head of the exact branch", () => {
    expect(parseLsRemoteHead("abc123\trefs/heads/task/X-1\n", "task/X-1")).toBe("abc123");
  });

  it("ignores refs that only share the suffix", () => {
    // ls-remote's pattern is a suffix match.
    const stdout = "fff000\trefs/heads/old/task/X-1\nabc123\trefs/heads/task/X-1\n";
    expect(parseLsRemoteHead(stdout, "task/X-1")).toBe("abc123");
    expect(parseLsRemoteHead("fff000\trefs/heads/old/task/X-1\n", "task/X-1")).toBeNull();
  });

  it("returns null on empty output", () => {
    expect(parseLsRemoteHead("", "task/X-1")).toBeNull();
  });
});
