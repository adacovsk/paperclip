import { Router } from "express";
import type { Db } from "@paperclipai/db";
import { patchInstanceExperimentalSettingsSchema, patchInstanceGeneralSettingsSchema } from "@paperclipai/shared";
import { validate } from "../middleware/validate.js";
import { instanceSettingsService, logActivity } from "../services/index.js";
import { assertInstanceAdmin, getActorInfo } from "./authz.js";

export function instanceSettingsRoutes(db: Db) {
  const router = Router();
  const svc = instanceSettingsService(db);

  router.get("/instance/settings/general", async (req, res) => {
    assertInstanceAdmin(req);
    res.json(await svc.getGeneral());
  });

  router.patch(
    "/instance/settings/general",
    validate(patchInstanceGeneralSettingsSchema),
    async (req, res) => {
      assertInstanceAdmin(req);
      const updated = await svc.updateGeneral(req.body);
      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "instance.settings.general_updated",
        entityType: "instance_settings",
        entityId: updated.id,
        details: {
          general: updated.general,
          changedKeys: Object.keys(req.body).sort(),
        },
      });
      res.json(updated.general);
    },
  );

  router.get("/instance/settings/experimental", async (req, res) => {
    assertInstanceAdmin(req);
    res.json(await svc.getExperimental());
  });

  router.patch(
    "/instance/settings/experimental",
    validate(patchInstanceExperimentalSettingsSchema),
    async (req, res) => {
      assertInstanceAdmin(req);
      const updated = await svc.updateExperimental(req.body);
      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "instance.settings.experimental_updated",
        entityType: "instance_settings",
        entityId: updated.id,
        details: {
          experimental: updated.experimental,
          changedKeys: Object.keys(req.body).sort(),
        },
      });
      res.json(updated.experimental);
    },
  );

  return router;
}
