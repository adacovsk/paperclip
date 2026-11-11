import type { Request } from "express";
import { forbidden, unauthorized } from "../errors.js";

export function assertOperator(req: Request) {
  if (req.actor.type !== "operator") {
    throw forbidden("Operator access required");
  }
}

export function assertInstanceAdmin(req: Request) {
  assertOperator(req);
  if (req.actor.source === "local_implicit" || req.actor.isInstanceAdmin) {
    return;
  }
  throw forbidden("Instance admin access required");
}

/**
 * Any authenticated principal may act on the instance, except an operator
 * session or key without an active membership, unless they are instance admin.
 */
export function assertInstanceAccess(req: Request) {
  if (req.actor.type === "none") {
    throw unauthorized();
  }
  if (
    req.actor.type === "operator"
    && req.actor.source !== "local_implicit"
    && !req.actor.isInstanceAdmin
    && !req.actor.isMember
  ) {
    throw forbidden("User does not have access to this instance");
  }
}

export function getActorInfo(req: Request) {
  if (req.actor.type === "none") {
    throw unauthorized();
  }
  if (req.actor.type === "agent") {
    return {
      actorType: "agent" as const,
      actorId: req.actor.agentId ?? "unknown-agent",
      agentId: req.actor.agentId ?? null,
      runId: req.actor.runId ?? null,
    };
  }

  return {
    actorType: "user" as const,
    actorId: req.actor.userId ?? "operator",
    agentId: null,
    runId: req.actor.runId ?? null,
  };
}
