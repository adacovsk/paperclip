import { pgTable, uuid, text, timestamp, uniqueIndex, index } from "drizzle-orm/pg-core";

export const memberships = pgTable(
  "memberships",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    principalType: text("principal_type").notNull(),
    principalId: text("principal_id").notNull(),
    status: text("status").notNull().default("active"),
    membershipRole: text("membership_role"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    principalUniqueIdx: uniqueIndex("memberships_principal_unique_idx").on(
      table.principalType,
      table.principalId,
    ),
    principalStatusIdx: index("memberships_principal_status_idx").on(
      table.principalType,
      table.principalId,
      table.status,
    ),
    statusIdx: index("memberships_status_idx").on(table.status),
  }),
);
