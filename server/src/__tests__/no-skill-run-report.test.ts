import { describe, expect, it } from "vitest";
import { resolveNoSkillCompletionStatus } from "../services/no-skill-completion-status.js";
import {
  ARCHITECT_ESCALATION_MARKER,
  RUN_REPORT_MAX_CHARS,
  extractRunResultText,
  findEscalationReason,
  planNoSkillRunReport,
} from "../services/no-skill-run-report.js";

const escalation = [
  "I didn't open a PR for task/X: the build is red in a file this task did not touch.",
  "",
  "- **Failing:** tests/combat.rs",
  "",
  `${ARCHITECT_ESCALATION_MARKER} red build outside this task's files`,
].join("\n");

describe("planNoSkillRunReport", () => {
  it("comments and blocks when an Architect run escalates with the marker", () => {
    for (const currentStatus of ["in_review", "in_progress", "todo"]) {
      const nextStatus = resolveNoSkillCompletionStatus({
        currentStatus,
        branchOnOrigin: true,
        branchMerged: false,
      });
      const plan = planNoSkillRunReport({ role: "architect", currentStatus, nextStatus, resultText: escalation });
      expect(plan.comment).toBe(escalation);
      expect(plan.block).toBe(true);
      expect(plan.escalationReason).toBe("red build outside this task's files");
    }
  });

  it("comments without touching status when an Architect run lands or launches a verify", () => {
    // Both exit 0 at `in_review` with nothing merged — the shape that cannot be
    // told apart from an escalation by run state alone.
    for (const resultText of [
      "I opened PR #12 for task/X: https://example.invalid/pull/12",
      "I sent the verify to the cloud lane and ended the run. No PR yet; a later wake lands it.",
    ]) {
      const plan = planNoSkillRunReport({
        role: "architect",
        currentStatus: "in_review",
        nextStatus: null,
        resultText,
      });
      expect(plan.comment).toBe(resultText);
      expect(plan.block).toBe(false);
    }
  });

  it("leaves a Worker completion alone", () => {
    for (const currentStatus of ["todo", "in_progress", "in_review"]) {
      const nextStatus = resolveNoSkillCompletionStatus({
        currentStatus,
        branchOnOrigin: false,
        branchMerged: false,
      });
      expect(
        planNoSkillRunReport({ role: "engineer", currentStatus, nextStatus, resultText: escalation }),
      ).toEqual({ comment: null, block: false, escalationReason: null });
    }
  });

  it("posts nothing for an empty result", () => {
    for (const resultText of ["", "   \n\t"]) {
      expect(
        planNoSkillRunReport({ role: "architect", currentStatus: "in_review", nextStatus: null, resultText }),
      ).toEqual({ comment: null, block: false, escalationReason: null });
    }
  });

  it("posts nothing once the branch has merged", () => {
    expect(
      planNoSkillRunReport({
        role: "architect",
        currentStatus: "in_review",
        nextStatus: "done",
        resultText: escalation,
      }).comment,
    ).toBeNull();
  });

  it("does not override a status someone else set", () => {
    // `blocked` is already where an escalation would put it; `backlog` was a
    // deliberate revert. The comment still lands so the reason is on record.
    for (const currentStatus of ["blocked", "backlog"]) {
      const plan = planNoSkillRunReport({
        role: "architect",
        currentStatus,
        nextStatus: null,
        resultText: escalation,
      });
      expect(plan.comment).toBe(escalation);
      expect(plan.block).toBe(false);
    }
  });

  it("keeps the escalation line when it truncates a long result", () => {
    const resultText = `${"x".repeat(RUN_REPORT_MAX_CHARS * 2)}\n${ARCHITECT_ESCALATION_MARKER} cap hit`;
    const plan = planNoSkillRunReport({ role: "architect", currentStatus: "in_review", nextStatus: null, resultText });
    expect(plan.comment!.length).toBeLessThan(RUN_REPORT_MAX_CHARS + 100);
    expect(plan.comment).toContain("characters omitted");
    expect(plan.comment!.endsWith(`${ARCHITECT_ESCALATION_MARKER} cap hit`)).toBe(true);
    expect(plan.block).toBe(true);
  });
});

describe("findEscalationReason", () => {
  it("requires the marker to start a line and carry a reason", () => {
    expect(findEscalationReason(`done.\n${ARCHITECT_ESCALATION_MARKER} stale base`)).toBe("stale base");
    expect(findEscalationReason(`  ${ARCHITECT_ESCALATION_MARKER}   stale base  `)).toBe("stale base");
    expect(findEscalationReason(`No need for ${ARCHITECT_ESCALATION_MARKER} here, it landed.`)).toBeNull();
    expect(findEscalationReason(`${ARCHITECT_ESCALATION_MARKER}`)).toBeNull();
    expect(findEscalationReason(`${ARCHITECT_ESCALATION_MARKER}   \nnext line`)).toBeNull();
  });
});

describe("extractRunResultText", () => {
  it("prefers the structured result and falls back to the summary", () => {
    expect(extractRunResultText({ resultJson: { result: " final " }, summary: "s" })).toBe("final");
    expect(extractRunResultText({ resultJson: { result: 3 }, summary: " s " })).toBe("s");
    expect(extractRunResultText({ resultJson: null, summary: null })).toBe("");
  });
});
