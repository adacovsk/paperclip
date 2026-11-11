import { Command } from "commander";
import type { ActivityEvent } from "@paperclipai/shared";
import {
  addCommonClientOptions,
  formatInlineRecord,
  handleCommandError,
  printOutput,
  resolveCommandContext,
  type BaseClientOptions,
} from "./common.js";

interface ActivityListOptions extends BaseClientOptions {
  agentId?: string;
  entityType?: string;
  entityId?: string;
}

export function registerActivityCommands(program: Command): void {
  const activity = program.command("activity").description("Activity log operations");

  addCommonClientOptions(
    activity
      .command("list")
      .description("List activity log entries")
      .option("--agent-id <id>", "Filter by agent ID")
      .option("--entity-type <type>", "Filter by entity type")
      .option("--entity-id <id>", "Filter by entity ID")
      .action(async (opts: ActivityListOptions) => {
        try {
          const ctx = resolveCommandContext(opts);
          const params = new URLSearchParams();
          if (opts.agentId) params.set("agentId", opts.agentId);
          if (opts.entityType) params.set("entityType", opts.entityType);
          if (opts.entityId) params.set("entityId", opts.entityId);

          const query = params.toString();
          const path = `/api/activity${query ? `?${query}` : ""}`;
          const rows = (await ctx.api.get<ActivityEvent[]>(path)) ?? [];

          if (ctx.json) {
            printOutput(rows, { json: true });
            return;
          }

          if (rows.length === 0) {
            printOutput([], { json: false });
            return;
          }

          for (const row of rows) {
            console.log(
              formatInlineRecord({
                id: row.id,
                action: row.action,
                actorType: row.actorType,
                actorId: row.actorId,
                entityType: row.entityType,
                entityId: row.entityId,
                createdAt: String(row.createdAt),
              }),
            );
          }
        } catch (err) {
          handleCommandError(err);
        }
      }),
  );
}
