import { pgTable, uuid, text, timestamp, jsonb, integer, boolean, uniqueIndex } from "drizzle-orm/pg-core";
import { assets } from "./assets.js";

export const instanceSettings = pgTable(
  "instance_settings",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    singletonKey: text("singleton_key").notNull().default("default"),
    general: jsonb("general").$type<Record<string, unknown>>().notNull().default({}),
    experimental: jsonb("experimental").$type<Record<string, unknown>>().notNull().default({}),
    // The instance is the top-level container; its own profile, issue numbering,
    // budget and fleet-wide switches live on this singleton row.
    name: text("name").notNull().default("Paperclip"),
    description: text("description"),
    status: text("status").notNull().default("active"),
    pauseReason: text("pause_reason"),
    pausedAt: timestamp("paused_at", { withTimezone: true }),
    // Issue identifiers are `${issuePrefix}-${issueCounter}`; the counter is bumped
    // with UPDATE ... RETURNING in the issue-create transaction.
    issuePrefix: text("issue_prefix").notNull().default("PAP"),
    issueCounter: integer("issue_counter").notNull().default(0),
    budgetMonthlyCents: integer("budget_monthly_cents").notNull().default(0),
    spentMonthlyCents: integer("spent_monthly_cents").notNull().default(0),
    requireOperatorApprovalForNewAgents: boolean("require_operator_approval_for_new_agents")
      .notNull()
      .default(true),
    brandColor: text("brand_color"),
    logoAssetId: uuid("logo_asset_id").references(() => assets.id, { onDelete: "set null" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    singletonKeyIdx: uniqueIndex("instance_settings_singleton_key_idx").on(table.singletonKey),
  }),
);
