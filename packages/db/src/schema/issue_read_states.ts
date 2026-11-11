import { pgTable, uuid, text, timestamp, index, uniqueIndex } from "drizzle-orm/pg-core";
import { issues } from "./issues.js";

export const issueReadStates = pgTable(
  "issue_read_states",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    issueId: uuid("issue_id").notNull().references(() => issues.id),
    userId: text("user_id").notNull(),
    lastReadAt: timestamp("last_read_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    issueIdx: index("issue_read_states_issue_idx").on(table.issueId),
    userIdx: index("issue_read_states_user_idx").on(table.userId),
    issueUserUnique: uniqueIndex("issue_read_states_issue_user_idx").on(
      table.issueId,
      table.userId,
    ),
  }),
);
