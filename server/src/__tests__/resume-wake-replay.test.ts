import { describe, expect, it } from "vitest";
import { selectAssignmentsToReplayOnResume } from "../services/resume-wake-replay.js";

const AGENT = "agent-1";
const OTHER = "agent-2";
const issue = (over: Partial<Parameters<typeof selectAssignmentsToReplayOnResume>[0][number]> = {}) => ({
  id: "i1",
  status: "todo",
  assigneeAgentId: AGENT,
  activeRunId: null,
  executionRunId: null,
  ...over,
});

describe("selectAssignmentsToReplayOnResume", () => {
  it("replays a task stranded by the pause window", () => {
    // The AA-5029 shape: assigned, dispatchable, never started.
    const stranded = issue({ id: "AA-5029", status: "todo" });
    expect(selectAssignmentsToReplayOnResume([stranded], AGENT)).toEqual([stranded]);
  });

  it("replays every dispatchable status", () => {
    for (const status of ["todo", "in_progress", "in_review"]) {
      expect(selectAssignmentsToReplayOnResume([issue({ status })], AGENT)).toHaveLength(1);
    }
  });

  it("never replays a non-dispatchable status", () => {
    // Waking a `blocked` assignee is actively destructive — a no-skill agent
    // cannot decline, exits 0, and the completion handler promotes it off
    // `blocked`. Resume must not become a second door into that loop.
    for (const status of ["backlog", "blocked"]) {
      expect(selectAssignmentsToReplayOnResume([issue({ status })], AGENT)).toEqual([]);
    }
  });

  it("ignores tasks assigned to another agent", () => {
    expect(selectAssignmentsToReplayOnResume([issue({ assigneeAgentId: OTHER })], AGENT)).toEqual([]);
    expect(selectAssignmentsToReplayOnResume([issue({ assigneeAgentId: null })], AGENT)).toEqual([]);
  });

  it("never replays onto a task that already holds a run", () => {
    expect(selectAssignmentsToReplayOnResume([issue({ activeRunId: "run-1" })], AGENT)).toEqual([]);
    expect(selectAssignmentsToReplayOnResume([issue({ executionRunId: "run-1" })], AGENT)).toEqual([]);
  });

  it("caps the batch so one resume cannot flood the queue", () => {
    const many = Array.from({ length: 40 }, (_, n) => issue({ id: `i${n}` }));
    expect(selectAssignmentsToReplayOnResume(many, AGENT)).toHaveLength(25);
    expect(selectAssignmentsToReplayOnResume(many, AGENT, 3)).toHaveLength(3);
  });

  it("is idempotent once the replayed wakes have minted runs", () => {
    // Second resume, same set: the first replay gave each task a run, so nothing
    // is re-fired. Reconciliation must converge, not oscillate.
    const first = [issue({ id: "a" }), issue({ id: "b" })];
    expect(selectAssignmentsToReplayOnResume(first, AGENT)).toHaveLength(2);
    const afterDispatch = first.map((i) => ({ ...i, executionRunId: "run" }));
    expect(selectAssignmentsToReplayOnResume(afterDispatch, AGENT)).toEqual([]);
  });
});
