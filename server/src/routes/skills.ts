import { Router, type Request } from "express";
import type { Db } from "@paperclipai/db";
import {
  skillCreateSchema,
  skillFileUpdateSchema,
  skillImportSchema,
  skillProjectScanRequestSchema,
} from "@paperclipai/shared";
import { validate } from "../middleware/validate.js";
import { accessService, agentService, skillService, logActivity } from "../services/index.js";
import { forbidden } from "../errors.js";
import { assertInstanceAccess, getActorInfo } from "./authz.js";

export function skillRoutes(db: Db) {
  const router = Router();
  const agents = agentService(db);
  const access = accessService(db);
  const svc = skillService(db);

  function canCreateAgents(agent: { permissions: Record<string, unknown> | null | undefined }) {
    if (!agent.permissions || typeof agent.permissions !== "object") return false;
    return Boolean((agent.permissions as Record<string, unknown>).canCreateAgents);
  }

  async function assertCanMutateSkills(req: Request) {
    assertInstanceAccess(req);

    if (req.actor.type === "operator") {
      if (req.actor.source === "local_implicit" || req.actor.isInstanceAdmin) return;
      const allowed = await access.canUser(req.actor.userId, "agents:create");
      if (!allowed) {
        throw forbidden("Missing permission: agents:create");
      }
      return;
    }

    if (!req.actor.agentId) {
      throw forbidden("Agent authentication required");
    }

    const actorAgent = await agents.getById(req.actor.agentId);
    if (!actorAgent) {
      throw forbidden("Agent authentication required");
    }

    const allowedByGrant = await access.hasPermission("agent", actorAgent.id, "agents:create");
    if (allowedByGrant || canCreateAgents(actorAgent)) {
      return;
    }

    throw forbidden("Missing permission: can create agents");
  }

  router.get("/skills", async (req, res) => {
    assertInstanceAccess(req);
    const result = await svc.list();
    res.json(result);
  });

  router.get("/skills/:skillId", async (req, res) => {
    const skillId = req.params.skillId as string;
    assertInstanceAccess(req);
    const result = await svc.detail(skillId);
    if (!result) {
      res.status(404).json({ error: "Skill not found" });
      return;
    }
    res.json(result);
  });

  router.get("/skills/:skillId/update-status", async (req, res) => {
    const skillId = req.params.skillId as string;
    assertInstanceAccess(req);
    const result = await svc.updateStatus(skillId);
    if (!result) {
      res.status(404).json({ error: "Skill not found" });
      return;
    }
    res.json(result);
  });

  router.get("/skills/:skillId/files", async (req, res) => {
    const skillId = req.params.skillId as string;
    const relativePath = String(req.query.path ?? "SKILL.md");
    assertInstanceAccess(req);
    const result = await svc.readFile(skillId, relativePath);
    if (!result) {
      res.status(404).json({ error: "Skill not found" });
      return;
    }
    res.json(result);
  });

  router.post(
    "/skills",
    validate(skillCreateSchema),
    async (req, res) => {
      await assertCanMutateSkills(req);
      const result = await svc.createLocalSkill(req.body);

      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "skill.created",
        entityType: "skill",
        entityId: result.id,
        details: {
          slug: result.slug,
          name: result.name,
        },
      });

      res.status(201).json(result);
    },
  );

  router.patch(
    "/skills/:skillId/files",
    validate(skillFileUpdateSchema),
    async (req, res) => {
      const skillId = req.params.skillId as string;
      await assertCanMutateSkills(req);
      const result = await svc.updateFile(
        skillId,
        String(req.body.path ?? ""),
        String(req.body.content ?? ""),
      );

      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "skill.file_updated",
        entityType: "skill",
        entityId: skillId,
        details: {
          path: result.path,
          markdown: result.markdown,
        },
      });

      res.json(result);
    },
  );

  router.post(
    "/skills/import",
    validate(skillImportSchema),
    async (req, res) => {
      await assertCanMutateSkills(req);
      const source = String(req.body.source ?? "");
      const result = await svc.importFromSource(source);

      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "skill.imported",
        entityType: "instance",
        entityId: "instance",
        details: {
          source,
          importedCount: result.imported.length,
          importedSlugs: result.imported.map((skill) => skill.slug),
          warningCount: result.warnings.length,
        },
      });

      res.status(201).json(result);
    },
  );

  router.post(
    "/skills/scan-projects",
    validate(skillProjectScanRequestSchema),
    async (req, res) => {
      await assertCanMutateSkills(req);
      const result = await svc.scanProjectWorkspaces(req.body);

      const actor = getActorInfo(req);
      await logActivity(db, {
        actorType: actor.actorType,
        actorId: actor.actorId,
        agentId: actor.agentId,
        runId: actor.runId,
        action: "skill.projects_scanned",
        entityType: "instance",
        entityId: "instance",
        details: {
          scannedProjects: result.scannedProjects,
          scannedWorkspaces: result.scannedWorkspaces,
          discovered: result.discovered,
          importedCount: result.imported.length,
          updatedCount: result.updated.length,
          conflictCount: result.conflicts.length,
          warningCount: result.warnings.length,
        },
      });

      res.json(result);
    },
  );

  router.delete("/skills/:skillId", async (req, res) => {
    const skillId = req.params.skillId as string;
    await assertCanMutateSkills(req);
    const result = await svc.deleteSkill(skillId);
    if (!result) {
      res.status(404).json({ error: "Skill not found" });
      return;
    }

    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      runId: actor.runId,
      action: "skill.deleted",
      entityType: "skill",
      entityId: result.id,
      details: {
        slug: result.slug,
        name: result.name,
      },
    });

    res.json(result);
  });

  router.post("/skills/:skillId/install-update", async (req, res) => {
    const skillId = req.params.skillId as string;
    await assertCanMutateSkills(req);
    const result = await svc.installUpdate(skillId);
    if (!result) {
      res.status(404).json({ error: "Skill not found" });
      return;
    }

    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      runId: actor.runId,
      action: "skill.update_installed",
      entityType: "skill",
      entityId: result.id,
      details: {
        slug: result.slug,
        sourceRef: result.sourceRef,
      },
    });

    res.json(result);
  });

  return router;
}
