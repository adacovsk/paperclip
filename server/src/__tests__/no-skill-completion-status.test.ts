import { describe, expect, it } from "vitest";
import { noSkillRunOwnsTask, resolveNoSkillCompletionStatus } from "../services/no-skill-completion-status.js";

describe("resolveNoSkillCompletionStatus", () => {
  it("auto-completes only when the branch is merged into the base ref", () => {
    for (const currentStatus of ["todo", "in_progress", "in_review", "blocked"]) {
      expect(
        resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: true, branchMerged: true }),
      ).toBe("done");
    }
  });

  it("never completes on a pushed-but-unmerged branch", () => {
    // Regression (AA-3297): `branchOnOrigin` means *pushed*, which a Worker does
    // on every successful run without merging anything. Treating it as landed
    // marked AA-3271 and AA-3021 `done` with their commits only on task/<id>,
    // and then oscillated against the Coordinator audit — flip, revert, flip —
    // three times over ~16 hours on AA-3179.
    for (const currentStatus of ["todo", "in_progress"]) {
      expect(
        resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: true, branchMerged: false }),
      ).toBe("in_review");
    }
    expect(
      resolveNoSkillCompletionStatus({
        currentStatus: "in_review",
        branchOnOrigin: true,
        branchMerged: false,
      }),
    ).toBeNull();
  });

  it("holds unlanded work at in_review", () => {
    for (const currentStatus of ["todo", "in_progress"]) {
      expect(
        resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: false, branchMerged: false }),
      ).toBe("in_review");
    }
  });

  it("leaves an already-in_review task alone", () => {
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "in_review", branchOnOrigin: false, branchMerged: false }),
    ).toBeNull();
  });

  it("never promotes a deliberately blocked task", () => {
    // Regression: a no-skill run exits 0 whether or not it did any work, so
    // reaching the completion handler is not evidence the block cleared.
    // Promoting to in_review discarded the coordinator's decision and re-entered
    // the task into the pipeline against a base commit missing its dependency.
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "blocked", branchOnOrigin: false, branchMerged: false }),
    ).toBeNull();
  });

  it("never promotes any status outside the active allowlist", () => {
    // Regression: the guard above was written as a denylist naming only
    // `blocked`, so every other non-active status still fell through to
    // in_review. A task reverted to `backlog` mid-run was flipped back into the
    // pipeline by the very run the revert was meant to abandon.
    for (const currentStatus of ["backlog", "cancelled", "done"]) {
      expect(resolveNoSkillCompletionStatus({ currentStatus, branchOnOrigin: false, branchMerged: false })).toBeNull();
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

describe("noSkillRunOwnsTask", () => {
  const architect = "architect-agent";
  const planner = "planner-agent";

  it("speaks for a task still assigned to the run's agent", () => {
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: architect })).toBe(true);
  });

  it("does not speak for a task routed to another agent mid-run", () => {
    // Regression: a Verify routed to the Planner on a `planner` hold is `todo`,
    // which the promotion allowlist accepts. The Architect run still in flight
    // then exited, flipped the Planner's task to `in_review` (clearing the hold)
    // and posted its final message after the `Held:` line.
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: planner })).toBe(false);
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "todo", branchOnOrigin: false, branchMerged: false }),
    ).toBe("in_review");
  });

  it("does not speak for a task parked unassigned mid-run", () => {
    // A hold that parks the task `blocked` clears the assignee.
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: null })).toBe(false);
  });
});
