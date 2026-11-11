import { pgTable, uuid, text, timestamp, index, uniqueIndex } from "drizzle-orm/pg-core";
import { issues } from "./issues.js";

export const issueInboxArchives = pgTable(
  "issue_inbox_archives",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    issueId: uuid("issue_id").notNull().references(() => issues.id),
    userId: text("user_id").notNull(),
    archivedAt: timestamp("archived_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    issueIdx: index("issue_inbox_archives_issue_idx").on(table.issueId),
    userIdx: index("issue_inbox_archives_user_idx").on(table.userId),
    issueUserUnique: uniqueIndex("issue_inbox_archives_issue_user_idx").on(
      table.issueId,
      table.userId,
    ),
  }),
);
