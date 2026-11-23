import { describe, expect, it } from "vitest";
import { checkTransition } from "../services/issue-status.js";
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
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "in_progress", branchOnOrigin: true, branchMerged: false }),
    ).toBe("in_review");
    expect(
      resolveNoSkillCompletionStatus({
        currentStatus: "in_review",
        branchOnOrigin: true,
        branchMerged: false,
      }),
    ).toBeNull();
  });

  it("holds unlanded work at in_review", () => {
    expect(
      resolveNoSkillCompletionStatus({ currentStatus: "in_progress", branchOnOrigin: false, branchMerged: false }),
    ).toBe("in_review");
  });

  it("leaves a task re-queued to todo mid-run where it is", () => {
    // The run's start moved `todo` to `in_progress`, so `todo` at its end is
    // another writer's re-queue. Promoting it is `todo -> in_review` with no
    // Worker pass behind it, which the transition table flags.
    for (const branchOnOrigin of [true, false]) {
      expect(
        resolveNoSkillCompletionStatus({ currentStatus: "todo", branchOnOrigin, branchMerged: false }),
      ).toBeNull();
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

describe("resolveNoSkillCompletionStatus against the transition table", () => {
  // The statuses the completion reaches the decision with: the heartbeat skips a
  // task that is already `done` or `cancelled` before deciding anything.
  const STATUSES = ["backlog", "todo", "in_progress", "in_review", "blocked"];
  const context = {
    actor: { actorType: "agent" as const, actorId: "a1", agentId: "a1" },
    source: "no_skill_completion" as const,
  };
  const issues = [
    { title: "Add the thing", dedupeKey: null },
    { title: "Verify: Add the thing", dedupeKey: "verify" },
  ];

  it("never decides a move the table flags, for any status or branch reading", () => {
    for (const from of STATUSES) {
      for (const [branchOnOrigin, branchMerged] of [[false, false], [true, false], [true, true]]) {
        const to = resolveNoSkillCompletionStatus({ currentStatus: from, branchOnOrigin, branchMerged });
        if (to === null) continue;
        for (const issue of issues) {
          expect(checkTransition({ from, to, context, issue }), `${from} -> ${to} (${issue.title})`).toEqual([]);
        }
      }
    }
  });

  it("still sends a Worker's finished run from in_progress to review", () => {
    const to = resolveNoSkillCompletionStatus({ currentStatus: "in_progress", branchOnOrigin: true, branchMerged: false });
    expect(to).toBe("in_review");
    expect(checkTransition({ from: "in_progress", to: "in_review", context, issue: issues[0] })).toEqual([]);
  });
});

describe("noSkillRunOwnsTask", () => {
  const architect = "architect-agent";
  const planner = "planner-agent";

  it("speaks for a task still assigned to the run's agent", () => {
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: architect })).toBe(true);
  });

  it("does not speak for a task routed to another agent mid-run", () => {
    // A Verify routed to the Planner on a `planner` hold: the Architect run
    // still in flight must not post its final message after the `Held:` line.
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: planner })).toBe(false);
  });

  it("does not speak for a task parked unassigned mid-run", () => {
    // A hold that parks the task `blocked` clears the assignee.
    expect(noSkillRunOwnsTask({ runAgentId: architect, assigneeAgentId: null })).toBe(false);
  });
});
