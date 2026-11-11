import { index, integer, pgTable, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";
import { agents } from "./agents.js";
import { issues } from "./issues.js";

export const issueBuilds = pgTable(
  "issue_builds",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    issueId: uuid("issue_id").notNull().references(() => issues.id, { onDelete: "cascade" }),
    stageIssueId: uuid("stage_issue_id").references(() => issues.id, { onDelete: "set null" }),
    exitCode: integer("exit_code").notNull(),
    lane: text("lane").notNull(),
    headSha: text("head_sha"),
    baseSha: text("base_sha"),
    host: text("host"),
    action: text("action"),
    note: text("note"),
    finishedAt: timestamp("finished_at", { withTimezone: true }).notNull(),
    reportedByAgentId: uuid("reported_by_agent_id").references(() => agents.id, { onDelete: "set null" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    issueFinishedIdx: index("issue_builds_issue_finished_idx").on(table.issueId, table.finishedAt),
    // One result per task per moment it finished. A reporter that sees the same
    // result twice writes the same row, so reporting needs no memory of its own.
    resultUq: uniqueIndex("issue_builds_result_uq").on(table.issueId, table.finishedAt),
  }),
);
