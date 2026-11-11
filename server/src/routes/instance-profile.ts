import { Router, type Request } from "express";
import type { Db } from "@paperclipai/db";
import { updateInstanceBrandingSchema, updateInstanceProfileSchema } from "@paperclipai/shared";
import { forbidden } from "../errors.js";
import { validate } from "../middleware/validate.js";
import { agentService, instanceProfileService, logActivity } from "../services/index.js";
import { assertInstanceAccess, assertOperator, getActorInfo } from "./authz.js";

export function instanceProfileRoutes(db: Db) {
  const router = Router();
  const svc = instanceProfileService(db);
  const agents = agentService(db);

  /** Operators may edit branding; among agents only the CEO may. */
  async function assertCanUpdateBranding(req: Request) {
    assertInstanceAccess(req);
    if (req.actor.type === "operator") return;
    if (!req.actor.agentId) throw forbidden("Agent authentication required");
    const actorAgent = await agents.getById(req.actor.agentId);
    if (!actorAgent || actorAgent.role !== "ceo") {
      throw forbidden("Only CEO agents can update instance branding");
    }
  }

  router.get("/instance/profile", async (req, res) => {
    assertInstanceAccess(req);
    res.json(await svc.get());
  });

  router.patch("/instance/profile", async (req, res) => {
    assertInstanceAccess(req);
    let body: Record<string, unknown>;
    if (req.actor.type === "agent") {
      await assertCanUpdateBranding(req);
      body = updateInstanceBrandingSchema.parse(req.body);
    } else {
      assertOperator(req);
      body = updateInstanceProfileSchema.parse(req.body);
    }

    const profile = await svc.update(body);
    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      runId: actor.runId,
      action: "instance.updated",
      entityType: "instance",
      entityId: profile.id,
      details: body,
    });
    res.json(profile);
  });

  router.patch("/instance/profile/branding", validate(updateInstanceBrandingSchema), async (req, res) => {
    await assertCanUpdateBranding(req);
    const profile = await svc.updateBranding(req.body);
    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      runId: actor.runId,
      action: "instance.branding_updated",
      entityType: "instance",
      entityId: profile.id,
      details: req.body,
    });
    res.json(profile);
  });

  return router;
}
