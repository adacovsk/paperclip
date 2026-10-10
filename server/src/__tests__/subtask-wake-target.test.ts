import { describe, expect, it } from "vitest";
import {
  commentWakesAssignee,
  resolveSubtaskWakeTarget,
  summarizeOpenChildren,
} from "../services/subtask-wake-target.js";

describe("resolveSubtaskWakeTarget", () => {
  it("suppresses the wake when the parent is already terminal", () => {
    // The AA-4004 evidence lands here: three of the no-op Worker runs measured on
    // 2026-09-11 were woken by a child completing under a parent that was already
    // `done`. The assignee on a done task is whoever last worked it, so waking
    // them buys a checkout, a git read and an exit.
    for (const parentStatus of ["done", "cancelled"]) {
      for (const hasOtherOpenChild of [true, false]) {
        expect(resolveSubtaskWakeTarget({ parentStatus, hasOtherOpenChild, assigneeOwnsOtherOpenChild: hasOtherOpenChild })).toEqual({
          kind: "none",
          reason: `parent is ${parentStatus}`,
        });
      }
    }
  });

  it("suppresses the wake when the parent row is missing", () => {
    expect(resolveSubtaskWakeTarget({ parentStatus: null, hasOtherOpenChild: false, assigneeOwnsOtherOpenChild: false })).toEqual({
      kind: "none",
      reason: "parent row not found",
    });
  });

  it("wakes the Coordinator when a Verify child finishes under an in_review parent", () => {
    // The shape the fix is named for: the Verify stage was the parent's last live
    // child, so the parent's assignee (a Worker) has nothing left to do. The
    // Coordinator is the next mover — it creates the next stage, or merges.
    expect(resolveSubtaskWakeTarget({ parentStatus: "in_review", hasOtherOpenChild: false, assigneeOwnsOtherOpenChild: false })).toEqual(
      { kind: "coordinator", reason: "parent is in_review with no other open child" },
    );
  });

  it("leaves an in_review parent whose assignee owns another live stage to that assignee", () => {
    // Preserves re-dispatch for the no-skill Architect that commits without
    // landing: that task carries its own non-terminal verify subtask, so it is
    // not childless and its assignee is still the next mover.
    expect(resolveSubtaskWakeTarget({ parentStatus: "in_review", hasOtherOpenChild: true, assigneeOwnsOtherOpenChild: true }),
    ).toEqual({ kind: "parent-assignee" });
  });

  it("wakes nobody when an in_review parent waits on a stage another agent owns", () => {
    // A Reviewer finished while the Architect's Verify is still open. The
    // parent's assignee (a Worker) cannot move it; the Verify's own completion
    // is the wake that will.
    expect(
      resolveSubtaskWakeTarget({ parentStatus: "in_review", hasOtherOpenChild: true, assigneeOwnsOtherOpenChild: false }),
    ).toEqual({ kind: "none", reason: "parent is in_review waiting on a stage another agent owns" });
  });

  it("leaves every in-flight parent status to its own assignee", () => {
    // Only `in_review` means "parked at the stage boundary". A parent that is
    // todo/in_progress/backlog/blocked is not waiting on the Coordinator to
    // create a stage, so the redirect must not reach it.
    for (const parentStatus of ["todo", "in_progress", "backlog", "blocked"]) {
      for (const hasOtherOpenChild of [true, false]) {
        expect(resolveSubtaskWakeTarget({ parentStatus, hasOtherOpenChild, assigneeOwnsOtherOpenChild: hasOtherOpenChild })).toEqual({
          kind: "parent-assignee",
        });
      }
    }
  });

  it("never resolves a target that would re-wake a terminal parent's assignee", () => {
    // The invariant the bug violated, asserted directly rather than inferred from
    // the cases above: no terminal parent may produce a wake of any kind.
    for (const parentStatus of ["done", "cancelled"]) {
      for (const hasOtherOpenChild of [true, false]) {
        expect(
          resolveSubtaskWakeTarget({ parentStatus, hasOtherOpenChild, assigneeOwnsOtherOpenChild: hasOtherOpenChild }).kind,
        ).toBe("none");
      }
    }
  });
});

describe("commentWakesAssignee", () => {
  it("does not wake an in_review assignee that owns none of the open children", () => {
    expect(commentWakesAssignee({ status: "in_review", assigneeOwnsOpenChild: false })).toBe(false);
  });

  it("wakes an in_review assignee that still owns an open child", () => {
    expect(commentWakesAssignee({ status: "in_review", assigneeOwnsOpenChild: true })).toBe(true);
  });

  it("wakes the assignee of any status other than in_review", () => {
    for (const status of ["todo", "in_progress", "backlog", "blocked"]) {
      expect(commentWakesAssignee({ status, assigneeOwnsOpenChild: false })).toBe(true);
    }
  });
});

describe("summarizeOpenChildren", () => {
  const WORKER = "worker";
  const ARCHITECT = "architect";

  it("does not count the parent assignee's own child parked in_review", () => {
    // The Worker's follow-up sibling is finished and parked beside the Verify
    // that just completed. Counting it routed the wake to the Worker.
    expect(summarizeOpenChildren([{ assigneeAgentId: WORKER, status: "in_review" }], WORKER)).toEqual({
      hasOtherOpenChild: false,
      assigneeOwnsOtherOpenChild: false,
    });
  });

  it("routes a Verify completion beside a parked own sibling to the Coordinator", () => {
    const summary = summarizeOpenChildren([{ assigneeAgentId: WORKER, status: "in_review" }], WORKER);
    expect(resolveSubtaskWakeTarget({ parentStatus: "in_review", ...summary }).kind).toBe("coordinator");
  });

  it("counts the parent assignee's own child while it is live", () => {
    for (const status of ["todo", "in_progress", "blocked", "backlog"]) {
      expect(summarizeOpenChildren([{ assigneeAgentId: WORKER, status }], WORKER)).toEqual({
        hasOtherOpenChild: true,
        assigneeOwnsOtherOpenChild: true,
      });
    }
  });

  it("keeps another agent's in_review child counted as someone still working", () => {
    // An Architect's Verify sits in_review while its build is in flight.
    expect(summarizeOpenChildren([{ assigneeAgentId: ARCHITECT, status: "in_review" }], WORKER)).toEqual({
      hasOtherOpenChild: true,
      assigneeOwnsOtherOpenChild: false,
    });
  });

  it("ignores terminal children and handles an unassigned parent", () => {
    expect(
      summarizeOpenChildren(
        [
          { assigneeAgentId: WORKER, status: "done" },
          { assigneeAgentId: null, status: "cancelled" },
        ],
        WORKER,
      ),
    ).toEqual({ hasOtherOpenChild: false, assigneeOwnsOtherOpenChild: false });
    expect(summarizeOpenChildren([{ assigneeAgentId: null, status: "in_review" }], null)).toEqual({
      hasOtherOpenChild: true,
      assigneeOwnsOtherOpenChild: false,
    });
  });
});
