import { describe, expect, it, vi } from "vitest";
import {
  isDispatchableIssueStatus,
  queueIssueAssignmentWakeup,
} from "../services/issue-assignment-wakeup.js";

function makeDeps() {
  return { wakeup: vi.fn().mockResolvedValue(null) };
}

describe("isDispatchableIssueStatus", () => {
  it("allows the statuses an assignee can actually work", () => {
    for (const status of ["todo", "in_progress", "in_review", "done", "cancelled"]) {
      expect(isDispatchableIssueStatus(status)).toBe(true);
    }
  });

  it("rejects backlog and blocked", () => {
    expect(isDispatchableIssueStatus("backlog")).toBe(false);
    expect(isDispatchableIssueStatus("blocked")).toBe(false);
  });
});

describe("queueIssueAssignmentWakeup", () => {
  it("wakes the assignee for a dispatchable issue", async () => {
    const heartbeat = makeDeps();
    await queueIssueAssignmentWakeup({
      heartbeat,
      issue: { id: "issue-1", assigneeAgentId: "agent-1", status: "todo" },
      reason: "issue_assigned",
      mutation: "update",
      contextSource: "issue.update",
    });
    expect(heartbeat.wakeup).toHaveBeenCalledTimes(1);
    expect(heartbeat.wakeup).toHaveBeenCalledWith(
      "agent-1",
      expect.objectContaining({ source: "assignment", reason: "issue_assigned" }),
    );
  });

  it("does not wake the assignee of a blocked issue", async () => {
    // Regression: a blocked task is a deliberate "do not run this yet". A
    // no-skill agent cannot decline it, its run exits 0 regardless, and the
    // completion handler used to promote the task off `blocked`. Correcting the
    // status usually re-sets the assignee, which re-fired this wake — a loop
    // that flipped one blocked task four times in a day.
    const heartbeat = makeDeps();
    await queueIssueAssignmentWakeup({
      heartbeat,
      issue: { id: "issue-1", assigneeAgentId: "agent-1", status: "blocked" },
      reason: "issue_assigned",
      mutation: "update",
      contextSource: "issue.update",
    });
    expect(heartbeat.wakeup).not.toHaveBeenCalled();
  });

  it("does not wake the assignee of a backlog issue", async () => {
    const heartbeat = makeDeps();
    await queueIssueAssignmentWakeup({
      heartbeat,
      issue: { id: "issue-1", assigneeAgentId: "agent-1", status: "backlog" },
      reason: "issue_assigned",
      mutation: "create",
      contextSource: "issue.create",
    });
    expect(heartbeat.wakeup).not.toHaveBeenCalled();
  });

  it("does not wake when the issue has no agent assignee", async () => {
    const heartbeat = makeDeps();
    await queueIssueAssignmentWakeup({
      heartbeat,
      issue: { id: "issue-1", assigneeAgentId: null, status: "todo" },
      reason: "issue_assigned",
      mutation: "update",
      contextSource: "issue.update",
    });
    expect(heartbeat.wakeup).not.toHaveBeenCalled();
  });
});
