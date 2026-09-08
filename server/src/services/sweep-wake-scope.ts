/**
 * A *sweep* wake tells an agent to re-read the whole board, not to execute the
 * task named in its payload.
 *
 * `subtask_completed` is the only wake with that shape. Its `payload.issueId` is
 * the task that just advanced — a pivot the recipient reads for context, never
 * work it is being dispatched onto. For a parentless task the recipient resolves
 * by `role = 'coordinator'`, so every stage exit in the fleet lands on one agent
 * whose response is a full pipeline scan.
 *
 * That distinction is load-bearing for coalescing. `enqueueWakeup` scopes a run
 * by task, so N completions on N different tasks are N different scopes and the
 * coalescing path never sees a match — the Coordinator ran 9 full sweeps in 38
 * minutes, later 10 in 70, each re-deriving an identical picture. Sweeps are
 * idempotent in a way per-task dispatches are not: one scan subsumes every wake
 * that arrived before it started, so they coalesce by *agent* instead.
 */
export const SWEEP_WAKE_SCOPE_KEY = "__sweep__";

export function isSweepWakeReason(reason: string | null | undefined): boolean {
  return reason === "subtask_completed";
}

/**
 * The coalescing scope for a wake: all sweeps for one agent share a scope, and
 * everything else keeps its per-task scope.
 */
export function wakeCoalesceScope(reason: string | null | undefined, taskKey: string | null): string | null {
  return isSweepWakeReason(reason) ? SWEEP_WAKE_SCOPE_KEY : taskKey;
}
