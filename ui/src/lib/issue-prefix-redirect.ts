/**
 * Paths whose first segment is a host route. An issue prefix that collides
 * with one of these never strips it, so `/org` stays `/org`.
 */
const HOST_ROUTE_ROOTS = new Set([
  "dashboard",
  "onboarding",
  "settings",
  "org",
  "agents",
  "projects",
  "issues",
  "routines",
  "skills",
  "goals",
  "approvals",
  "costs",
  "activity",
  "inbox",
  "design-guide",
  "tests",
  "execution-workspaces",
  "instance",
  "auth",
  "invite",
  "operator-claim",
  "cli-auth",
]);

/**
 * Links written into issue comments carry the instance's issue prefix as their
 * first segment (`/AA/issues/AA-123`). Returns the same URL with that segment
 * removed, or `null` when the path does not start with the prefix.
 */
export function stripIssuePrefixFromPath(
  path: string,
  issuePrefix: string | null | undefined,
): string | null {
  if (!issuePrefix) return null;
  const match = path.match(/^\/([^/?#]+)(.*)$/);
  if (!match) return null;
  const [, first, rest] = match;
  if (first!.toLowerCase() !== issuePrefix.toLowerCase()) return null;
  if (HOST_ROUTE_ROOTS.has(first!.toLowerCase())) return null;
  if (!rest || rest.startsWith("?") || rest.startsWith("#")) return `/${rest ?? ""}`.replace(/^\/\//, "/");
  return rest;
}
