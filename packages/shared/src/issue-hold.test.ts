import { describe, expect, it } from "vitest";
import {
  formatHoldLine,
  holdSurvivesStatus,
  isHoldLine,
  parseHoldLine,
  sameHoldCondition,
  type IssueHoldBlocker,
} from "./issue-hold.js";

const blocker = (n: number): IssueHoldBlocker => ({ id: `id-${n}`, identifier: `AA-${n}` });

describe("parseHoldLine", () => {
  it("reads nothing from a comment that declares no hold", () => {
    expect(parseHoldLine("Rebased onto main.")).toBeNull();
    expect(parseHoldLine("Note\nHeld: until AA-1 merges")).toBeNull();
    expect(isHoldLine("  Held: planner")).toBe(true);
  });

  it("reads the merge and PR release conditions, singular and plural", () => {
    expect(parseHoldLine("Held: until AA-12 merges")).toEqual({
      kind: "until_merge",
      blockerIdentifiers: ["AA-12"],
      note: null,
    });
    expect(parseHoldLine("Held: until AA-1 and AA-2 merge — shares the loader")).toEqual({
      kind: "until_merge",
      blockerIdentifiers: ["AA-1", "AA-2"],
      note: "shares the loader",
    });
    expect(parseHoldLine("Held: until AA-1, AA-2, and AA-3 open their PRs")).toEqual({
      kind: "until_pr",
      blockerIdentifiers: ["AA-1", "AA-2", "AA-3"],
      note: null,
    });
    expect(parseHoldLine("Held: until AA-7 opens its PR (same file)\nmore detail")).toEqual({
      kind: "until_pr",
      blockerIdentifiers: ["AA-7"],
      note: "same file)",
    });
  });

  it("reads `waiting on` as the blocker being closed", () => {
    expect(parseHoldLine("Held: waiting on AA-9")).toEqual({
      kind: "until_merge",
      blockerIdentifiers: ["AA-9"],
      note: null,
    });
  });

  it("reads the holds that wait on a decision", () => {
    expect(parseHoldLine("Held: planner — spec names a module that does not exist")?.kind).toBe("planner");
    expect(parseHoldLine("Held: operator: needs a credential")).toEqual({
      kind: "operator",
      blockerIdentifiers: [],
      note: "needs a credential",
    });
    expect(parseHoldLine("Held: worktree allocation failed")?.kind).toBe("worktree");
  });

  it("keeps a line in no known form as kind other, with the line as its note", () => {
    expect(parseHoldLine("Held: until the nightly is green")).toEqual({
      kind: "other",
      blockerIdentifiers: [],
      note: "until the nightly is green",
    });
    expect(parseHoldLine("Held: waiting on the operator")?.kind).toBe("other");
  });
});

describe("formatHoldLine", () => {
  it("writes lines parseHoldLine reads back", () => {
    const cases = [
      { kind: "until_merge", blockers: [blocker(1)], note: null },
      { kind: "until_merge", blockers: [blocker(1), blocker(2)], note: "builds on both" },
      { kind: "until_pr", blockers: [blocker(1)], note: null },
      { kind: "until_pr", blockers: [blocker(1), blocker(2), blocker(3)], note: "same files" },
      { kind: "planner", blockers: [], note: "ambiguous claim" },
      { kind: "operator", blockers: [], note: null },
      { kind: "worktree", blockers: [], note: null },
      { kind: "other", blockers: [], note: "until the nightly is green" },
    ] as const;
    for (const hold of cases) {
      const parsed = parseHoldLine(formatHoldLine({ ...hold, blockers: [...hold.blockers] }));
      expect(parsed).toEqual({
        kind: hold.kind,
        blockerIdentifiers: hold.blockers.map((b) => b.identifier),
        note: hold.note,
      });
    }
  });

  it("writes the forms the release sweep matches", () => {
    expect(formatHoldLine({ kind: "until_merge", blockers: [blocker(1), blocker(2)], note: null })).toBe(
      "Held: until AA-1 and AA-2 merge",
    );
    expect(formatHoldLine({ kind: "until_pr", blockers: [blocker(1), blocker(2), blocker(3)], note: null })).toBe(
      "Held: until AA-1, AA-2 and AA-3 open their PRs",
    );
  });
});

describe("sameHoldCondition", () => {
  it("compares kind and the set of blockers, not their order or the note", () => {
    const a = { kind: "until_pr" as const, blockers: [blocker(1), blocker(2)] };
    expect(sameHoldCondition(a, { kind: "until_pr", blockers: [blocker(2), blocker(1)] })).toBe(true);
    expect(sameHoldCondition(a, { kind: "until_merge", blockers: [blocker(1), blocker(2)] })).toBe(false);
    expect(sameHoldCondition(a, { kind: "until_pr", blockers: [blocker(1)] })).toBe(false);
    expect(sameHoldCondition(a, null)).toBe(false);
  });
});

describe("holdSurvivesStatus", () => {
  it("lets only a Planner hold stand on a todo task", () => {
    expect(holdSurvivesStatus("until_merge", "blocked")).toBe(true);
    expect(holdSurvivesStatus("until_merge", "todo")).toBe(false);
    expect(holdSurvivesStatus("planner", "todo")).toBe(true);
    expect(holdSurvivesStatus("planner", "in_progress")).toBe(false);
  });
});
