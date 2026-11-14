import { describe, expect, it } from "vitest";
import {
  checkTransition,
  ISSUE_STATUS_TRANSITIONS,
  type IssueStatusSource,
  type IssueWriteContext,
} from "../services/issue-status.ts";

const STATUSES = ["backlog", "todo", "in_progress", "in_review", "blocked", "done", "cancelled"];

const agent = (source: IssueStatusSource): IssueWriteContext => ({
  actor: { actorType: "agent", actorId: "a1", agentId: "a1" },
  source,
});
const operator = (source: IssueStatusSource): IssueWriteContext => ({
  actor: { actorType: "user", actorId: "local-operator" },
  source,
});
const system = (source: IssueStatusSource): IssueWriteContext => ({
  actor: { actorType: "system", actorId: "issue_service" },
  source,
});
const task = { title: "Add the thing", dedupeKey: null };

const kinds = (...args: Parameters<typeof checkTransition>) => checkTransition(...args).map((flag) => flag.kind);

describe("ISSUE_STATUS_TRANSITIONS", () => {
  it("rules on every pair of distinct statuses, and on nothing else", () => {
    expect(Object.keys(ISSUE_STATUS_TRANSITIONS).sort()).toEqual([...STATUSES].sort());
    for (const from of STATUSES) {
      const expected = STATUSES.filter((to) => to !== from).sort();
      expect(Object.keys(ISSUE_STATUS_TRANSITIONS[from]).sort(), from).toEqual(expected);
    }
  });

  it("lets done and cancelled out only through a reopen, or to review for the operator", () => {
    for (const from of ["done", "cancelled"]) {
      const exits = ISSUE_STATUS_TRANSITIONS[from];
      expect(Object.entries(exits).filter(([, rule]) => rule === "allow").map(([to]) => to), from).toEqual(["todo"]);
      expect(exits.in_review, from).toBe("operator");
    }
  });

  it("reaches backlog only from work that has not started", () => {
    const into = STATUSES.filter((from) => from !== "backlog" && ISSUE_STATUS_TRANSITIONS[from].backlog === "allow");
    expect(into.sort()).toEqual(["blocked", "todo"]);
  });
});

describe("checkTransition", () => {
  it("passes an allowed move, and a same-status write", () => {
    expect(kinds({ from: "in_review", to: "done", context: agent("issue_patch"), issue: task })).toEqual([]);
    expect(kinds({ from: "done", to: "done", context: agent("issue_patch"), issue: task })).toEqual([]);
  });

  it("flags a rejected move whoever makes it", () => {
    expect(kinds({ from: "cancelled", to: "done", context: agent("issue_patch"), issue: task })).toEqual(["rejected"]);
    expect(kinds({ from: "cancelled", to: "done", context: operator("issue_patch"), issue: task })).toEqual(["rejected"]);
  });

  it("flags an operator-only move made by an agent or the server, not by the operator", () => {
    expect(kinds({ from: "done", to: "in_review", context: agent("issue_patch"), issue: task })).toEqual(["operator_only"]);
    expect(kinds({ from: "done", to: "in_review", context: system("unspecified"), issue: task })).toEqual(["operator_only"]);
    expect(kinds({ from: "done", to: "in_review", context: operator("issue_patch"), issue: task })).toEqual([]);
  });

  it("flags todo -> in_review only on a task that is not a stage subtask", () => {
    expect(kinds({ from: "todo", to: "in_review", context: agent("issue_patch"), issue: task })).toEqual(["review_without_work"]);
    // The Verify queue: filed todo with no build slot, dispatched to review when one frees.
    for (const issue of [
      { title: "Verify: X-1 Add the thing", dedupeKey: null },
      { title: "anything", dedupeKey: "verify" },
      { title: "ci-fix: abc123 red main", dedupeKey: null },
    ]) {
      expect(kinds({ from: "todo", to: "in_review", context: agent("issue_patch"), issue }), issue.title).toEqual([]);
    }
  });

  it("flags blocked -> in_review when a run's completion makes it, not a hold release", () => {
    expect(kinds({ from: "blocked", to: "in_review", context: agent("no_skill_completion"), issue: task }))
      .toEqual(["completion_over_hold"]);
    expect(kinds({ from: "blocked", to: "in_review", context: agent("issue_patch"), issue: task })).toEqual([]);
  });

  it("flags in_progress entered other than by checkout or a run start", () => {
    expect(kinds({ from: "todo", to: "in_progress", context: agent("checkout"), issue: task })).toEqual([]);
    expect(kinds({ from: "todo", to: "in_progress", context: agent("no_skill_run_start"), issue: task })).toEqual([]);
    expect(kinds({ from: "todo", to: "in_progress", context: agent("issue_patch"), issue: task }))
      .toEqual(["in_progress_without_run"]);
  });

  it("reports every problem with one move", () => {
    expect(kinds({ from: "done", to: "in_progress", context: operator("issue_patch"), issue: task }))
      .toEqual(["rejected", "in_progress_without_run"]);
  });
});
