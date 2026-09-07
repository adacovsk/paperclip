import { describe, expect, it } from "vitest";
import { resolveNoSkillCompletionStatus } from "../services/no-skill-completion-status.js";
import { shouldWakeNextMover } from "../services/stage-completion-wake.js";

describe("shouldWakeNextMover", () => {
  it("wakes on any status transition the run produced", () => {
    for (const nextStatus of ["done", "in_review"] as const) {
      for (const currentStatus of ["todo", "in_progress", "in_review", "blocked", "backlog"]) {
        expect(shouldWakeNextMover({ currentStatus, nextStatus })).toBe(true);
      }
    }
  });

  it("wakes a task already parked at the stage boundary even with no transition", () => {
    // A verify or a re-dispatched stage finishing at `in_review` moves work onto
    // the branch without moving the status. That is still a completion the next
    // mover owes an action on.
    expect(shouldWakeNextMover({ currentStatus: "in_review", nextStatus: null })).toBe(true);
  });

  it("suppresses the wake when nothing advanced and the status says nothing should", () => {
    for (const currentStatus of ["blocked", "backlog", "cancelled", "done"]) {
      expect(shouldWakeNextMover({ currentStatus, nextStatus: null })).toBe(false);
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
          expect(shouldWakeNextMover({ currentStatus, nextStatus })).toBe(true);
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
      expect(shouldWakeNextMover({ currentStatus, nextStatus })).toBe(!executorLoggedNoAdvance);
    }
  });
});
