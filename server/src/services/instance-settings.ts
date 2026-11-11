import type { Db } from "@paperclipai/db";
import { instanceSettings } from "@paperclipai/db";
import {
  instanceGeneralSettingsSchema,
  type InstanceGeneralSettings,
  instanceExperimentalSettingsSchema,
  type InstanceExperimentalSettings,
  type PatchInstanceGeneralSettings,
  type InstanceSettings,
  type PatchInstanceExperimentalSettings,
} from "@paperclipai/shared";
import { eq } from "drizzle-orm";

export const DEFAULT_SINGLETON_KEY = "default";

function normalizeGeneralSettings(raw: unknown): InstanceGeneralSettings {
  const parsed = instanceGeneralSettingsSchema.safeParse(raw ?? {});
  if (parsed.success) {
    return {
      censorUsernameInLogs: parsed.data.censorUsernameInLogs ?? false,
    };
  }
  return {
    censorUsernameInLogs: false,
  };
}

function normalizeExperimentalSettings(raw: unknown): InstanceExperimentalSettings {
  const parsed = instanceExperimentalSettingsSchema.safeParse(raw ?? {});
  if (parsed.success) {
    return {
      enableIsolatedWorkspaces: parsed.data.enableIsolatedWorkspaces ?? false,
      autoRestartDevServerWhenIdle: parsed.data.autoRestartDevServerWhenIdle ?? false,
    };
  }
  return {
    enableIsolatedWorkspaces: false,
    autoRestartDevServerWhenIdle: false,
  };
}

function toInstanceSettings(row: typeof instanceSettings.$inferSelect): InstanceSettings {
  return {
    id: row.id,
    general: normalizeGeneralSettings(row.general),
    experimental: normalizeExperimentalSettings(row.experimental),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

/** Reads the singleton `instance_settings` row, creating it on first access. */
export async function getOrCreateInstanceSettingsRow(db: Pick<Db, "select" | "insert">) {
  const existing = await db
    .select()
    .from(instanceSettings)
    .where(eq(instanceSettings.singletonKey, DEFAULT_SINGLETON_KEY))
    .then((rows) => rows[0] ?? null);
  if (existing) return existing;

  const now = new Date();
  const [created] = await db
    .insert(instanceSettings)
    .values({
      singletonKey: DEFAULT_SINGLETON_KEY,
      general: {},
      experimental: {},
      createdAt: now,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: [instanceSettings.singletonKey],
      set: {
        updatedAt: now,
      },
    })
    .returning();

  return created;
}

export function instanceSettingsService(db: Db) {
  const getOrCreateRow = () => getOrCreateInstanceSettingsRow(db);

  return {
    getRow: getOrCreateRow,

    get: async (): Promise<InstanceSettings> => toInstanceSettings(await getOrCreateRow()),

    getGeneral: async (): Promise<InstanceGeneralSettings> => {
      const row = await getOrCreateRow();
      return normalizeGeneralSettings(row.general);
    },

    getExperimental: async (): Promise<InstanceExperimentalSettings> => {
      const row = await getOrCreateRow();
      return normalizeExperimentalSettings(row.experimental);
    },

    updateGeneral: async (patch: PatchInstanceGeneralSettings): Promise<InstanceSettings> => {
      const current = await getOrCreateRow();
      const nextGeneral = normalizeGeneralSettings({
        ...normalizeGeneralSettings(current.general),
        ...patch,
      });
      const now = new Date();
      const [updated] = await db
        .update(instanceSettings)
        .set({
          general: { ...nextGeneral },
          updatedAt: now,
        })
        .where(eq(instanceSettings.id, current.id))
        .returning();
      return toInstanceSettings(updated ?? current);
    },

    updateExperimental: async (patch: PatchInstanceExperimentalSettings): Promise<InstanceSettings> => {
      const current = await getOrCreateRow();
      const nextExperimental = normalizeExperimentalSettings({
        ...normalizeExperimentalSettings(current.experimental),
        ...patch,
      });
      const now = new Date();
      const [updated] = await db
        .update(instanceSettings)
        .set({
          experimental: { ...nextExperimental },
          updatedAt: now,
        })
        .where(eq(instanceSettings.id, current.id))
        .returning();
      return toInstanceSettings(updated ?? current);
    },
  };
}
