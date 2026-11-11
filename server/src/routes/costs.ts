import { Router } from "express";
import type { Db } from "@paperclipai/db";
import {
  createCostEventSchema,
  createFinanceEventSchema,
  resolveBudgetIncidentSchema,
  updateBudgetSchema,
  upsertBudgetPolicySchema,
} from "@paperclipai/shared";
import { validate } from "../middleware/validate.js";
import {
  budgetService,
  costService,
  financeService,
  instanceProfileService,
  agentService,
  heartbeatService,
  logActivity,
} from "../services/index.js";
import { assertOperator, assertInstanceAccess, getActorInfo } from "./authz.js";
import { badRequest } from "../errors.js";

export function costRoutes(db: Db) {
  const router = Router();
  const heartbeat = heartbeatService(db);
  const budgetHooks = {
    cancelWorkForScope: heartbeat.cancelBudgetScopeWork,
  };
  const costs = costService(db, budgetHooks);
  const finance = financeService(db);
  const budgets = budgetService(db, budgetHooks);
  const instanceProfile = instanceProfileService(db);
  const agents = agentService(db);

  router.post("/cost-events", validate(createCostEventSchema), async (req, res) => {
    assertInstanceAccess(req);

    if (req.actor.type === "agent" && req.actor.agentId !== req.body.agentId) {
      res.status(403).json({ error: "Agent can only report its own costs" });
      return;
    }

    const event = await costs.createEvent({
      ...req.body,
      occurredAt: new Date(req.body.occurredAt),
    });

    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      action: "cost.reported",
      entityType: "cost_event",
      entityId: event.id,
      details: { costCents: event.costCents, model: event.model },
    });

    res.status(201).json(event);
  });

  router.post("/finance-events", validate(createFinanceEventSchema), async (req, res) => {
    assertInstanceAccess(req);
    assertOperator(req);

    const event = await finance.createEvent({
      ...req.body,
      occurredAt: new Date(req.body.occurredAt),
    });

    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      action: "finance_event.reported",
      entityType: "finance_event",
      entityId: event.id,
      details: {
        amountCents: event.amountCents,
        biller: event.biller,
        eventKind: event.eventKind,
        direction: event.direction,
      },
    });

    res.status(201).json(event);
  });

  function parseDateRange(query: Record<string, unknown>) {
    const fromRaw = query.from as string | undefined;
    const toRaw = query.to as string | undefined;
    const from = fromRaw ? new Date(fromRaw) : undefined;
    const to = toRaw ? new Date(toRaw) : undefined;
    if (from && isNaN(from.getTime())) throw badRequest("invalid 'from' date");
    if (to && isNaN(to.getTime())) throw badRequest("invalid 'to' date");
    return (from || to) ? { from, to } : undefined;
  }

  function parseLimit(query: Record<string, unknown>) {
    const raw = Array.isArray(query.limit) ? query.limit[0] : query.limit;
    if (raw == null || raw === "") return 100;
    const limit = typeof raw === "number" ? raw : Number.parseInt(String(raw), 10);
    if (!Number.isFinite(limit) || limit <= 0 || limit > 500) {
      throw badRequest("invalid 'limit' value");
    }
    return limit;
  }

  router.get("/costs/summary", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const summary = await costs.summary(range);
    res.json(summary);
  });

  router.get("/costs/by-agent", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await costs.byAgent(range);
    res.json(rows);
  });

  router.get("/costs/by-agent-model", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await costs.byAgentModel(range);
    res.json(rows);
  });

  router.get("/costs/by-provider", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await costs.byProvider(range);
    res.json(rows);
  });

  router.get("/costs/by-biller", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await costs.byBiller(range);
    res.json(rows);
  });

  router.get("/costs/finance-summary", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const summary = await finance.summary(range);
    res.json(summary);
  });

  router.get("/costs/finance-by-biller", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await finance.byBiller(range);
    res.json(rows);
  });

  router.get("/costs/finance-by-kind", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await finance.byKind(range);
    res.json(rows);
  });

  router.get("/costs/finance-events", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const limit = parseLimit(req.query);
    const rows = await finance.list(range, limit);
    res.json(rows);
  });

  router.get("/costs/window-spend", async (req, res) => {
    assertInstanceAccess(req);
    const rows = await costs.windowSpend();
    res.json(rows);
  });

  router.get("/budgets/overview", async (req, res) => {
    assertInstanceAccess(req);
    const overview = await budgets.overview();
    res.json(overview);
  });

  router.post(
    "/budgets/policies",
    validate(upsertBudgetPolicySchema),
    async (req, res) => {
      assertOperator(req);
      assertInstanceAccess(req);
      const summary = await budgets.upsertPolicy(req.body, req.actor.userId ?? "operator");
      res.json(summary);
    },
  );

  router.post(
    "/budget-incidents/:incidentId/resolve",
    validate(resolveBudgetIncidentSchema),
    async (req, res) => {
      assertOperator(req);
      const incidentId = req.params.incidentId as string;
      assertInstanceAccess(req);
      const incident = await budgets.resolveIncident(incidentId, req.body, req.actor.userId ?? "operator");
      res.json(incident);
    },
  );

  router.get("/costs/by-project", async (req, res) => {
    assertInstanceAccess(req);
    const range = parseDateRange(req.query);
    const rows = await costs.byProject(range);
    res.json(rows);
  });

  router.patch("/budgets", validate(updateBudgetSchema), async (req, res) => {
    assertOperator(req);
    assertInstanceAccess(req);
    const profile = await instanceProfile.update({ budgetMonthlyCents: req.body.budgetMonthlyCents });

    await logActivity(db, {
      actorType: "user",
      actorId: req.actor.userId ?? "operator",
      action: "instance.budget_updated",
      entityType: "instance",
      entityId: profile.id,
      details: { budgetMonthlyCents: req.body.budgetMonthlyCents },
    });

    await budgets.upsertPolicy(
      {
        scopeType: "instance",
        scopeId: profile.id,
        amount: req.body.budgetMonthlyCents,
        windowKind: "calendar_month_utc",
      },
      req.actor.userId ?? "operator",
    );

    res.json(profile);
  });

  router.patch("/agents/:agentId/budgets", validate(updateBudgetSchema), async (req, res) => {
    const agentId = req.params.agentId as string;
    const agent = await agents.getById(agentId);
    if (!agent) {
      res.status(404).json({ error: "Agent not found" });
      return;
    }

    assertInstanceAccess(req);

    if (req.actor.type === "agent") {
      if (req.actor.agentId !== agentId) {
        res.status(403).json({ error: "Agent can only change its own budget" });
        return;
      }
    }

    const updated = await agents.update(agentId, { budgetMonthlyCents: req.body.budgetMonthlyCents });
    if (!updated) {
      res.status(404).json({ error: "Agent not found" });
      return;
    }

    const actor = getActorInfo(req);
    await logActivity(db, {
      actorType: actor.actorType,
      actorId: actor.actorId,
      agentId: actor.agentId,
      action: "agent.budget_updated",
      entityType: "agent",
      entityId: updated.id,
      details: { budgetMonthlyCents: updated.budgetMonthlyCents },
    });

    await budgets.upsertPolicy(
      {
        scopeType: "agent",
        scopeId: updated.id,
        amount: updated.budgetMonthlyCents,
        windowKind: "calendar_month_utc",
      },
      req.actor.type === "operator" ? req.actor.userId ?? "operator" : null,
    );

    res.json(updated);
  });

  return router;
}
