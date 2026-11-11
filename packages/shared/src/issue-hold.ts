/**
 * A hold: why a task that could otherwise be dispatched is parked, and what
 * releases it.
 *
 * A hold used to be three unconnected facts: status `blocked`, no assignee, and
 * a comment whose first line began `Held:`. Readers recovered the release
 * condition by matching that line against patterns, so a line in a form no
 * pattern knew was a block nothing would ever release, and a later comment on
 * the task hid the hold from a reader that looked only at the newest one. The
 * hold is a field on the task instead; the comment line is its rendering.
 */

export const ISSUE_HOLD_KINDS = [
  /** Builds on the blockers' code: released when every blocker is done or cancelled. */
  "until_merge",
  /** Contends with the blockers for the same files: released once each has an open PR, or is closed. */
  "until_pr",
  /** A decision the Planner owns. Nothing mechanical releases it. */
  "planner",
  /** A decision only the operator can make. */
  "operator",
  /** No worktree could be allocated for the task. */
  "worktree",
  /** A `Held:` comment in a form that names no release condition. */
  "other",
] as const;
export type IssueHoldKind = (typeof ISSUE_HOLD_KINDS)[number];

/** Kinds whose release is a condition on other tasks, so they must name at least one. */
export const ISSUE_HOLD_BLOCKER_KINDS: readonly IssueHoldKind[] = ["until_merge", "until_pr"];

export interface IssueHoldBlocker {
  id: string;
  identifier: string;
}

export interface IssueHold {
  kind: IssueHoldKind;
  blockers: IssueHoldBlocker[];
  note: string | null;
  /**
   * The same condition on the same blockers was held before and then cleared.
   * A hold released on an open PR and written again is a correction: the writer
   * means the blocker's merge, whatever kind the hold carries.
   */
  reheld: boolean;
  setAt: string;
  setByAgentId: string | null;
  setByUserId: string | null;
}

/** A `Held:` line reduced to its parts, before its blockers are looked up. */
export interface ParsedHoldLine {
  kind: IssueHoldKind;
  blockerIdentifiers: string[];
  note: string | null;
}

const HOLD_PREFIX = /^\s*Held:\s*/;
const TASK_IDENTIFIER = /[A-Z]+-\d+/g;
const HELD_UNTIL =
  /^until ([A-Z]+-\d+(?:(?:,? and |, )[A-Z]+-\d+)*) (merges?|opens its PR|open their PRs)\b/;
const HELD_WAITING_ON = /^waiting on ([A-Z]+-\d+)\b/;
const FIXED_KINDS: ReadonlyArray<[string, IssueHoldKind]> = [
  ["planner", "planner"],
  ["operator", "operator"],
  ["worktree allocation failed", "worktree"],
];

function firstLine(body: string): string {
  return body.trim().split("\n", 1)[0] ?? "";
}

function noteFrom(rest: string): string | null {
  const note = rest.replace(/^[\s—–\-:;,.()]+/, "").trim();
  return note.length > 0 ? note : null;
}

/** Whether a comment's first line declares a hold. */
export function isHoldLine(body: string): boolean {
  return HOLD_PREFIX.test(firstLine(body));
}

/**
 * Read the hold a comment's first line declares, or null when it declares none.
 *
 * `Held: waiting on <id>` does not say whether it waits on the merge or the PR,
 * so it takes the reading both agree on: the blocker being closed.
 */
export function parseHoldLine(body: string): ParsedHoldLine | null {
  const line = firstLine(body);
  if (!HOLD_PREFIX.test(line)) return null;
  const text = line.replace(HOLD_PREFIX, "");

  const until = HELD_UNTIL.exec(text);
  if (until) {
    return {
      kind: until[2]!.startsWith("merge") ? "until_merge" : "until_pr",
      blockerIdentifiers: until[1]!.match(TASK_IDENTIFIER) ?? [],
      note: noteFrom(text.slice(until[0].length)),
    };
  }
  const waiting = HELD_WAITING_ON.exec(text);
  if (waiting) {
    return {
      kind: "until_merge",
      blockerIdentifiers: [waiting[1]!],
      note: noteFrom(text.slice(waiting[0].length)),
    };
  }
  for (const [prefix, kind] of FIXED_KINDS) {
    if (text.startsWith(prefix)) {
      return { kind, blockerIdentifiers: [], note: noteFrom(text.slice(prefix.length)) };
    }
  }
  return { kind: "other", blockerIdentifiers: [], note: noteFrom(text) };
}

function joinIdentifiers(identifiers: string[]): string {
  if (identifiers.length <= 1) return identifiers.join("");
  return `${identifiers.slice(0, -1).join(", ")} and ${identifiers.at(-1)}`;
}

/** The `Held:` line for a hold. `parseHoldLine` reads back what this writes. */
export function formatHoldLine(hold: Pick<IssueHold, "kind" | "blockers" | "note">): string {
  const ids = hold.blockers.map((blocker) => blocker.identifier);
  const many = ids.length > 1;
  const head = (() => {
    switch (hold.kind) {
      case "until_merge":
        return `Held: until ${joinIdentifiers(ids)} ${many ? "merge" : "merges"}`;
      case "until_pr":
        return `Held: until ${joinIdentifiers(ids)} ${many ? "open their PRs" : "opens its PR"}`;
      case "planner":
        return "Held: planner";
      case "operator":
        return "Held: operator";
      case "worktree":
        return "Held: worktree allocation failed";
      case "other":
        return "Held:";
    }
  })();
  if (!hold.note) return head;
  return hold.kind === "other" ? `${head} ${hold.note}` : `${head} — ${hold.note}`;
}

/** Whether two holds wait on the same thing: same kind, same set of blockers. */
export function sameHoldCondition(
  a: Pick<IssueHold, "kind" | "blockers"> | null | undefined,
  b: Pick<IssueHold, "kind" | "blockers"> | null | undefined,
): boolean {
  if (!a || !b || a.kind !== b.kind || a.blockers.length !== b.blockers.length) return false;
  const ids = new Set(a.blockers.map((blocker) => blocker.id));
  return b.blockers.every((blocker) => ids.has(blocker.id));
}

/**
 * Statuses a hold of this kind stays in force under. Every hold lives on a
 * `blocked` task. A Planner hold also survives `todo`: the Planner wakes only on
 * assignment, and the server fires no assignment wake on a `blocked` task, so
 * handing it the decision means `todo` with the hold still standing.
 */
export function holdSurvivesStatus(kind: IssueHoldKind, status: string): boolean {
  return status === "blocked" || (kind === "planner" && status === "todo");
}
