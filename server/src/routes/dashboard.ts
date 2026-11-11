import { Router } from "express";
import type { Db } from "@paperclipai/db";
import { dashboardService } from "../services/dashboard.js";
import { assertInstanceAccess } from "./authz.js";

export function dashboardRoutes(db: Db) {
  const router = Router();
  const svc = dashboardService(db);

  router.get("/dashboard", async (req, res) => {
    assertInstanceAccess(req);
    const summary = await svc.summary();
    res.json(summary);
  });

  return router;
}
