import { index, integer, pgTable, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";
import { agents } from "./agents.js";
import { issues } from "./issues.js";

export const issueGithubLinks = pgTable(
  "issue_github_links",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    issueId: uuid("issue_id").notNull().references(() => issues.id, { onDelete: "cascade" }),
    repo: text("repo").notNull(),
    number: integer("number").notNull(),
    linkedByAgentId: uuid("linked_by_agent_id").references(() => agents.id, { onDelete: "set null" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    // Linking is idempotent: a task links an issue once, however often it is sent.
    linkUq: uniqueIndex("issue_github_links_uq").on(table.issueId, table.repo, table.number),
    // The sweep reads every task linked to one repository's issues.
    repoNumberIdx: index("issue_github_links_repo_number_idx").on(table.repo, table.number),
  }),
);
