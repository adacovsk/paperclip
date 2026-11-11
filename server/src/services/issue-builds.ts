import { desc, eq, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { issueBuilds } from "@paperclipai/db";
import { describeBuildExit, type IssueBuild, type IssueBuildLane, type ReportIssueBuild } from "@paperclipai/shared";

const DEFAULT_LIST_LIMIT = 50;

function toBuild(row: typeof issueBuilds.$inferSelect): IssueBuild {
  return { ...row, lane: row.lane as IssueBuildLane, ...describeBuildExit(row.exitCode) };
}

export function issueBuildService(db: Db) {
  return {
    /**
     * Record a build result, or update the record of one already reported.
     *
     * A result is identified by its task and the moment it finished, so a
     * reporter may send the same one any number of times. What the pipeline did
     * with a result is known later than the result itself; a repeat report fills
     * that in and never blanks what an earlier one said.
     */
    report: async (issueId: string, input: ReportIssueBuild, reportedByAgentId: string | null) => {
      const values = {
        issueId,
        stageIssueId: input.stageIssueId ?? null,
        exitCode: input.exitCode,
        lane: input.lane,
        headSha: input.headSha ?? null,
        baseSha: input.baseSha ?? null,
        host: input.host ?? null,
        action: input.action ?? null,
        note: input.note ?? null,
        finishedAt: new Date(input.finishedAt),
        reportedByAgentId,
      };
      const keep = (column: keyof typeof values & string, sqlName: string) =>
        sql`coalesce(excluded.${sql.raw(sqlName)}, ${issueBuilds[column as "host"]})`;
      const [row] = await db
        .insert(issueBuilds)
        .values(values)
        .onConflictDoUpdate({
          target: [issueBuilds.issueId, issueBuilds.finishedAt],
          set: {
            exitCode: values.exitCode,
            lane: values.lane,
            stageIssueId: keep("stageIssueId", "stage_issue_id"),
            headSha: keep("headSha", "head_sha"),
            baseSha: keep("baseSha", "base_sha"),
            host: keep("host", "host"),
            action: keep("action", "action"),
            note: keep("note", "note"),
            updatedAt: new Date(),
          },
        })
        .returning();
      return toBuild(row!);
    },

    /** A task's build results, newest first. */
    listForIssue: async (issueId: string, limit = DEFAULT_LIST_LIMIT) => {
      const rows = await db
        .select()
        .from(issueBuilds)
        .where(eq(issueBuilds.issueId, issueId))
        .orderBy(desc(issueBuilds.finishedAt))
        .limit(limit);
      return rows.map(toBuild);
    },
  };
}
