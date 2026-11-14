/**
 * A task's link to the GitHub issue it was filed from.
 *
 * The link is a field, not a line in the task body: an issue number that only
 * travels as text is dropped by whichever hand-written step forgets to copy it,
 * and then nothing can tell which work an issue is waiting on. Links are
 * inherited from the parent on create, so every stage of a task carries them.
 */
export interface IssueGithubLink {
  id: string;
  issueId: string;
  /** `owner/name`. */
  repo: string;
  number: number;
  linkedByAgentId: string | null;
  createdAt: Date;
}

/** A link joined with the task it belongs to, as the reverse lookup returns it. */
export interface GithubIssueLinkedTask extends IssueGithubLink {
  identifier: string | null;
  title: string;
  status: string;
  parentId: string | null;
}

export const GITHUB_REPO_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

export function githubIssueUrl(link: { repo: string; number: number }): string {
  return `https://github.com/${link.repo}/issues/${link.number}`;
}
