/**
 * Render a task's operator-written comments for an agent that cannot read them.
 *
 * An agent without the `paperclip` skill has no API access: its prompt carries
 * the task's title and description and nothing else. A ruling the operator posts
 * as a comment ("rework this", "resume at step 3", "the guard is right, drop the
 * change") therefore never reached it, and it read the description, found the
 * branch already doing what the description asks, and committed nothing, run
 * after run, while the ruling sat one API call away.
 *
 * Only comments a person wrote are carried (`authorUserId` set). Agent comments
 * are status chatter the operator's ruling already answers, and including them
 * would grow every prompt with the pipeline's own narration.
 *
 * Extracted from the heartbeat run executor so the policy is testable without a
 * DB, like `planNoSkillRunReport`.
 */

export interface OperatorComment {
  authorUserId: string | null;
  body: string;
  createdAt: Date | string;
}

/** At most this many notes, newest first: the newest ruling is the one in force. */
export const OPERATOR_NOTES_MAX = 5;
/** Per-note cap, keeping the head, where a ruling states what to do. */
export const OPERATOR_NOTE_MAX_CHARS = 4000;

/** Markdown for the prompt's operator-notes slot, or "" when there are none. */
export function renderOperatorNotes(comments: OperatorComment[]): string {
  const notes = comments
    .filter((c) => c.authorUserId && c.body.trim().length > 0)
    .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
    .slice(0, OPERATOR_NOTES_MAX);
  if (notes.length === 0) return "";
  const rendered = notes.map((c) => {
    const at = new Date(c.createdAt).toISOString();
    const body = c.body.trim();
    const clipped = body.length > OPERATOR_NOTE_MAX_CHARS ? `${body.slice(0, OPERATOR_NOTE_MAX_CHARS)}\n\n[truncated]` : body;
    return `### ${at}\n\n${clipped}`;
  });
  return [
    "## Operator notes on this task (newest first)",
    "",
    "These were written by the operator after the description, and override it where they differ.",
    "",
    rendered.join("\n\n"),
  ].join("\n");
}
