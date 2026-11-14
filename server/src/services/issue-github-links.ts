import { and, asc, eq } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { issueGithubLinks, issues } from "@paperclipai/db";
import type { GithubIssueLinkedTask, GithubIssueRef, IssueGithubLink } from "@paperclipai/shared";

export function issueGithubLinkService(db: Db) {
  return {
    /**
     * Link a task to GitHub issues. Linking an issue the task already has is a
     * no-op, so a caller may send the whole set again. Returns the task's links.
     */
    link: async (issueId: string, refs: GithubIssueRef[], linkedByAgentId: string | null) => {
      if (refs.length > 0) {
        await db
          .insert(issueGithubLinks)
          .values(refs.map((ref) => ({ issueId, repo: ref.repo, number: ref.number, linkedByAgentId })))
          .onConflictDoNothing({
            target: [issueGithubLinks.issueId, issueGithubLinks.repo, issueGithubLinks.number],
          });
      }
      return listForIssue(db, issueId);
    },

    /**
     * Give a new task its parent's links plus any it was created with.
     *
     * A Review, Verify or rebase stage is filed by a script that knows nothing
     * about the issue its parent came from; inheriting here is what keeps every
     * stage of the work answerable to that issue.
     */
    linkOnCreate: async (
      issueId: string,
      parentId: string | null | undefined,
      refs: GithubIssueRef[],
      linkedByAgentId: string | null,
    ) => {
      const inherited = parentId ? await listForIssue(db, parentId) : [];
      const all = [...inherited.map((l) => ({ repo: l.repo, number: l.number })), ...refs];
      if (all.length === 0) return [];
      await db
        .insert(issueGithubLinks)
        .values(all.map((ref) => ({ issueId, repo: ref.repo, number: ref.number, linkedByAgentId })))
        .onConflictDoNothing({
          target: [issueGithubLinks.issueId, issueGithubLinks.repo, issueGithubLinks.number],
        });
      return listForIssue(db, issueId);
    },

    listForIssue: (issueId: string) => listForIssue(db, issueId),

    /** Remove one link from a task. Returns the removed link, or null if the task has no such link. */
    unlink: async (issueId: string, linkId: string) => {
      const [row] = await db
        .delete(issueGithubLinks)
        .where(and(eq(issueGithubLinks.id, linkId), eq(issueGithubLinks.issueId, issueId)))
        .returning();
      return (row as IssueGithubLink | undefined) ?? null;
    },

    /** Every task linked to a repository's issues, or to one of them, with each task's status. */
    linkedTasks: async (repo: string, number?: number): Promise<GithubIssueLinkedTask[]> => {
      const where = number === undefined
        ? eq(issueGithubLinks.repo, repo)
        : and(eq(issueGithubLinks.repo, repo), eq(issueGithubLinks.number, number));
      return db
        .select({
          id: issueGithubLinks.id,
          issueId: issueGithubLinks.issueId,
          repo: issueGithubLinks.repo,
          number: issueGithubLinks.number,
          linkedByAgentId: issueGithubLinks.linkedByAgentId,
          createdAt: issueGithubLinks.createdAt,
          identifier: issues.identifier,
          title: issues.title,
          status: issues.status,
          parentId: issues.parentId,
        })
        .from(issueGithubLinks)
        .innerJoin(issues, eq(issues.id, issueGithubLinks.issueId))
        .where(where)
        .orderBy(asc(issueGithubLinks.number), asc(issues.createdAt));
    },
  };
}

async function listForIssue(db: Db, issueId: string): Promise<IssueGithubLink[]> {
  return db
    .select()
    .from(issueGithubLinks)
    .where(eq(issueGithubLinks.issueId, issueId))
    .orderBy(asc(issueGithubLinks.repo), asc(issueGithubLinks.number));
}
