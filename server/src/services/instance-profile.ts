import { and, eq, gte, lt, sql } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { assets, costEvents, instanceSettings } from "@paperclipai/db";
import type { InstanceProfile, InstanceStatus, PauseReason } from "@paperclipai/shared";
import { notFound } from "../errors.js";
import { getOrCreateInstanceSettingsRow } from "./instance-settings.js";

type InstanceSettingsRow = typeof instanceSettings.$inferSelect;

export type InstanceProfilePatch = Partial<
  Pick<
    InstanceSettingsRow,
    | "name"
    | "description"
    | "status"
    | "pauseReason"
    | "pausedAt"
    | "budgetMonthlyCents"
    | "spentMonthlyCents"
    | "requireOperatorApprovalForNewAgents"
    | "brandColor"
    | "logoAssetId"
  >
>;

function currentUtcMonthWindow(now = new Date()) {
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth();
  return {
    start: new Date(Date.UTC(year, month, 1, 0, 0, 0, 0)),
    end: new Date(Date.UTC(year, month + 1, 1, 0, 0, 0, 0)),
  };
}

async function monthlySpendCents(database: Pick<Db, "select">) {
  const { start, end } = currentUtcMonthWindow();
  const [row] = await database
    .select({ total: sql<number>`coalesce(sum(${costEvents.costCents}), 0)::int` })
    .from(costEvents)
    .where(and(gte(costEvents.occurredAt, start), lt(costEvents.occurredAt, end)));
  return Number(row?.total ?? 0);
}

function toProfile(row: InstanceSettingsRow, spentMonthlyCents: number): InstanceProfile {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    status: row.status as InstanceStatus,
    pauseReason: (row.pauseReason as PauseReason | null) ?? null,
    pausedAt: row.pausedAt,
    issuePrefix: row.issuePrefix,
    issueCounter: row.issueCounter,
    budgetMonthlyCents: row.budgetMonthlyCents,
    spentMonthlyCents,
    requireOperatorApprovalForNewAgents: row.requireOperatorApprovalForNewAgents,
    brandColor: row.brandColor,
    logoAssetId: row.logoAssetId,
    logoUrl: row.logoAssetId ? `/api/assets/${row.logoAssetId}/content` : null,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

/** The instance's own record (name, branding, status, budget, issue numbering). */
export function instanceProfileService(db: Db) {
  async function get(): Promise<InstanceProfile> {
    const row = await getOrCreateInstanceSettingsRow(db);
    return toProfile(row, await monthlySpendCents(db));
  }

  async function update(patch: InstanceProfilePatch): Promise<InstanceProfile> {
    return db.transaction(async (tx) => {
      const existing = await getOrCreateInstanceSettingsRow(tx);
      const { logoAssetId } = patch;
      if (logoAssetId !== undefined && logoAssetId !== null) {
        const logoAsset = await tx
          .select({ id: assets.id })
          .from(assets)
          .where(eq(assets.id, logoAssetId))
          .then((rows) => rows[0] ?? null);
        if (!logoAsset) throw notFound("Logo asset not found");
      }

      const [updated] = await tx
        .update(instanceSettings)
        .set({ ...patch, updatedAt: new Date() })
        .where(eq(instanceSettings.id, existing.id))
        .returning();

      if (logoAssetId !== undefined && existing.logoAssetId && existing.logoAssetId !== logoAssetId) {
        await tx.delete(assets).where(eq(assets.id, existing.logoAssetId));
      }

      return toProfile(updated ?? existing, await monthlySpendCents(tx));
    });
  }

  return {
    get,
    update,
    updateBranding: (
      patch: Pick<InstanceProfilePatch, "name" | "description" | "brandColor" | "logoAssetId">,
    ) => update(patch),
  };
}
