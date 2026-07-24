import { describe, expect, it } from "vitest";
import { resolveNoSkillCompletionStatus } from "../services/no-skill-completion-status.js";

describe("resolveNoSkillCompletionStatus", () => {
  it("auto-completes only when the branch is confirmed on origin", () => {
    for (const currentStatus of ["todo", "in_progress", "in_review", "blocked"]) {
      expect(resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: true })).toBe("done");
    }
  });

  it("holds unlanded work at in_review", () => {
    for (const currentStatus of ["todo", "in_progress"]) {
      expect(resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: false })).toBe(
        "in_review",
      );
    }
  });

  it("leaves an already-in_review task alone", () => {
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "in_review", branchOnOrigin: false }),
    ).toBeNull();
  });

  it("never promotes a deliberately blocked task", () => {
    // Regression: a no-skill run exits 0 whether or not it did any work, so
    // reaching the completion handler is not evidence the block cleared.
    // Promoting to in_review discarded the coordinator's decision and re-entered
    // the task into the pipeline against a base commit missing its dependency.
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "blocked", branchOnOrigin: false }),
    ).toBeNull();
  });

  it("never promotes any status outside the active allowlist", () => {
    // Regression: the guard above was written as a denylist naming only
    // `blocked`, so every other non-active status still fell through to
    // in_review. A task reverted to `backlog` mid-run was flipped back into the
    // pipeline by the very run the revert was meant to abandon.
    for (const currentStatus of ["backlog", "cancelled", "done"]) {
      expect(resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: false })).toBeNull();
    }
  });

  it("does not promote an unrecognized status", () => {
    // The allowlist must fail closed: a status added to the system later has to
    // opt in to promotion rather than silently inherit it.
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "some_future_status", branchOnOrigin: false }),
    ).toBeNull();
  });
});
