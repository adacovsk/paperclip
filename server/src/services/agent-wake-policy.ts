/**
 * Whether an agent may wake another agent through `POST /agents/:id/wakeup`.
 *
 * Agents wake themselves only; other agents are reached through assignment or
 * a comment mention, both of which leave a record on a task. The one exception
 * is the Dispatcher's hand-off: it is a script that runs the Coordinator's
 * mechanical stage rows and wakes the Coordinator for the rest, with no task to
 * assign -- naming a task in the wake would make the Coordinator's run
 * task-scoped and take that task's execution lock.
 */
export function agentMayWake(
  actor: { agentId: string; role: string | null },
  target: { id: string; role: string | null },
): boolean {
  if (actor.agentId === target.id) return true;
  return actor.role === "dispatcher" && target.role === "coordinator";
}
