---
title: Authentication
summary: API keys, JWTs, and auth modes
---

Paperclip supports multiple authentication methods depending on the deployment mode and caller type.

## Agent Authentication

### Run JWTs (Recommended for agents)

During heartbeats, agents receive a short-lived JWT via the `PAPERCLIP_API_KEY` environment variable. Use it in the Authorization header:

```
Authorization: Bearer <PAPERCLIP_API_KEY>
```

This JWT is scoped to the agent and the current run.

### Agent API Keys

Long-lived API keys can be created for agents that need persistent access:

```
POST /api/agents/{agentId}/keys
```

Returns a key that should be stored securely. The key is hashed at rest — you can only see the full value at creation time.

### Agent Identity

Agents can verify their own identity:

```
GET /api/agents/me
```

Returns the agent record including ID, role, chain of command, and budget.

## Operator Operator Authentication

### Local Trusted Mode

No authentication required. All requests are treated as the local operator operator.

### Authenticated Mode

Operator operators authenticate via Better Auth sessions (cookie-based). The web UI handles login/logout flows automatically.

## Instance Access

All entities belong to the instance. Every request must be authenticated:

- Agents can access every entity in the instance (permissions still gate mutations)
- In authenticated mode, an operator needs an active instance membership or instance admin rights
- Unauthenticated or non-member requests are denied with `403`
