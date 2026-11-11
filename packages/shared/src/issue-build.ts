/**
 * A build result: what one verify of a task's branch came back with.
 *
 * The result used to exist only as a file on the machine that ran the build,
 * named after the task and holding an exit code. Every reader had to be on that
 * machine and had to know the code table. The record carries the same facts to
 * the server, where the task page and any other machine can read them.
 */

export const ISSUE_BUILD_LANES = ["local", "cloud"] as const;
export type IssueBuildLane = (typeof ISSUE_BUILD_LANES)[number];

export const ISSUE_BUILD_OUTCOMES = ["green", "red", "superseded", "fault"] as const;
/**
 * `green` and `red` are verdicts on the code. `superseded` means the work is
 * already on main. `fault` is everything that says nothing about the code: the
 * build did not run, did not finish, or its result could not be trusted.
 */
export type IssueBuildOutcome = (typeof ISSUE_BUILD_OUTCOMES)[number];

interface BuildExitMeaning {
  outcome: IssueBuildOutcome;
  label: string;
}

/** What each exit code a build can report means. Unlisted codes are faults. */
export const ISSUE_BUILD_EXIT_CODES: Readonly<Record<number, BuildExitMeaning>> = {
  0: { outcome: "green", label: "Green" },
  1: { outcome: "red", label: "Red" },
  64: { outcome: "fault", label: "Refused: a chained cargo call" },
  75: { outcome: "fault", label: "Worktree lock timed out" },
  94: { outcome: "superseded", label: "Superseded: already on main" },
  95: { outcome: "fault", label: "Cloud result rejected at the trust boundary" },
  96: { outcome: "fault", label: "Environment fault" },
  97: { outcome: "fault", label: "Worktree missing" },
  98: { outcome: "fault", label: "Base sync failed" },
  99: { outcome: "fault", label: "Inconclusive" },
  100: { outcome: "fault", label: "Build reaped" },
  137: { outcome: "fault", label: "Out of memory" },
};

export function describeBuildExit(exitCode: number): BuildExitMeaning {
  return ISSUE_BUILD_EXIT_CODES[exitCode] ?? { outcome: "fault", label: `Exit ${exitCode}` };
}

export interface IssueBuild {
  id: string;
  /** The task whose branch was built. */
  issueId: string;
  /** The Verify stage that asked for the build, when there was one. */
  stageIssueId: string | null;
  exitCode: number;
  outcome: IssueBuildOutcome;
  label: string;
  lane: IssueBuildLane;
  headSha: string | null;
  baseSha: string | null;
  /** The machine that ran the build. */
  host: string | null;
  /** What the pipeline did with the result, and why. */
  action: string | null;
  note: string | null;
  finishedAt: Date;
  reportedByAgentId: string | null;
  createdAt: Date;
  updatedAt: Date;
}
