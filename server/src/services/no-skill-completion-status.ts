/**
 * Decide what status a task should carry after a run by an agent that lacks the
 * `paperclip` skill (Worker / Architect). Those agents cannot PATCH their own
 * status, so the server reflects the run outcome into the task for them.
 *
 * Extracted from the heartbeat run executor so the policy is testable without a
 * DB, a git remote, or an adapter.
 */
export function resolveNoSkillCompletionStatus(input: {
  /** The task's status at the moment the run finished. */
  currentStatus: string;
  /**
   * True only on a positive `git ls-remote` confirmation that the task branch
   * exists on origin. This means **pushed**, which is not the same as landed — a
   * Worker pushes by design without merging anything.
   */
  branchOnOrigin: boolean;
  /**
   * True only on a positive `git merge-base --is-ancestor` confirmation that the
   * branch is reachable from the base ref. This is the *only* evidence that the
   * work actually landed.
   */
  branchMerged: boolean;
}): "done" | "in_review" | null {
  // Layer-2 anti-masquerade invariant: a no-skill task may auto-complete only
  // when its work is reachable from the base ref.
  //
  // This deliberately tests `branchMerged`, NOT `branchOnOrigin`. Pushing is what
  // a Worker does on every successful run; treating it as "landed" marked tasks
  // `done` whose commits were only ever on `task/<id>` (AA-3271, AA-3021), and
  // `done` is what unblocks dependents and counts as shipped.
  //
  // The failure was worse than a mislabel: it oscillated. The gate flipped a task
  // to `done`, Coordinator's PR-evidence audit reverted it to `in_review`, the
  // next run re-checked, the branch was still pushed, and it flipped back —
  // three times over ~16 hours on AA-3179, while agents kept committing to a task
  // the server had already declared finished. Two layers disagreeing about the
  // meaning of "done", on independent cadences, is a loop the audit cannot win.
  if (input.branchMerged) return "done";

  // Promotion is an ALLOWLIST, not a denylist. A no-skill run exits 0 whether or
  // not it did any work, so reaching this point is no evidence about the task —
  // only the task's own status says whether a promotion is wanted. One status
  // describes a task that was dispatched and is still in flight, and therefore
  // legitimately owes an `in_review`: `in_progress`, which the run's own start
  // wrote (`no_skill_run_start`, `todo -> in_progress`).
  //
  // Every other status is someone's deliberate decision that this task is not
  // advancing, and promoting it silently discards that decision:
  //   - `todo`      — queued for work. The run's start moved a `todo` task to
  //                   `in_progress`, so finding `todo` at the run's end means
  //                   another writer re-queued it while the run was in flight
  //                   (a reset for a fresh Worker pass, a reopen, an unblock of
  //                   a task the run started on while held). The queued pass
  //                   has not run; `todo -> in_review` on a task that is not a
  //                   stage subtask skips its Worker, which the transition table
  //                   flags as `review_without_work`. The dispatcher picks the
  //                   task up from `todo` as it is.
  //   - `blocked`   — coordinator/operator held it (usually an unmerged
  //                   cross-task dependency); promoting re-enters it into the
  //                   pipeline against a base commit that lacks that dependency.
  //   - `backlog`   — reverted out of the pipeline, typically mid-run, for
  //                   exactly that reason.
  //   - `cancelled` — abandoned; resurrecting it is strictly wrong.
  //   - `done`      — already terminal.
  //   - `in_review` — already where it needs to be.
  //
  // Keep this an allowlist: a status added to the system later must opt IN to
  // promotion rather than silently inherit it.
  if (input.currentStatus === "in_progress") return "in_review";

  return null;
}

/**
 * Whether a finished no-skill run still speaks for its task, so the server may
 * act on the task for it: promote its status, post the run's final message and
 * wake the next mover.
 *
 * Only while the task is still assigned to the run's agent. A stage reassigned
 * mid-run (the Dispatcher routing a Verify to the Planner on a `planner` hold,
 * or parking it `blocked` and unassigned) belongs to its new owner from that
 * write on, and the old run's exit is not news about it. Acting on it anyway
 * did two kinds of damage. The run's final message landed after the `Held:`
 * line, burying it for any reader of the newest comment. Worse, the old run's
 * exit could promote the Planner's task to `in_review`, which clears the hold
 * and is a status the Planner never reads, so the stage sat with no run. The run's own record keeps its result either way.
 */
export function noSkillRunOwnsTask(input: {
  /** The agent whose run just finished. */
  runAgentId: string;
  /** The task's agent assignee at the moment the run finished. */
  assigneeAgentId: string | null;
}): boolean {
  return input.assigneeAgentId === input.runAgentId;
}
