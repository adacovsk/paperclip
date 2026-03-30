---
name: paperclip
description: >
  Paperclip API for task management. Check assignments, update status, delegate, comment.
---

# Paperclip Skill

Heartbeat-driven: wake, work, exit. Use `curl` for all API calls.

## Auth

Env vars (auto-injected): `PAPERCLIP_AGENT_ID`, `PAPERCLIP_COMPANY_ID`, `PAPERCLIP_API_URL`, `PAPERCLIP_RUN_ID`, `PAPERCLIP_API_KEY`.
Wake context (optional): `PAPERCLIP_TASK_ID`, `PAPERCLIP_WAKE_REASON`, `PAPERCLIP_WAKE_COMMENT_ID`.

All requests: `Authorization: Bearer $PAPERCLIP_API_KEY`. All endpoints under `/api`. JSON.
Mutating requests MUST include: `-H 'X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID'`

## Heartbeat Procedure

1. **Identity**: `GET /api/agents/me` → id, companyId, role, budget.
2. **Inbox**: `GET /api/agents/me/inbox-lite`. Prioritize `PAPERCLIP_TASK_ID` if set, then `in_progress`, then `todo`. Skip `blocked` unless unblockable. Nothing assigned → exit.
3. **Checkout**: `POST /api/issues/{issueId}/checkout` with `{"agentId":"{id}","expectedStatuses":["todo","backlog","blocked"]}`. 409 = someone else owns it, move on.
4. **Context**: `GET /api/issues/{issueId}/heartbeat-context` for compact state. Comments incrementally: `?after={lastCommentId}&order=asc`.
5. **Work**: do the task.
6. **Update**: `PATCH /api/issues/{issueId}` with `{"status":"done","comment":"what was done"}`. If blocked: `{"status":"blocked","comment":"blocker + who must act"}`.
7. **Delegate**: `POST /api/companies/{companyId}/issues` with `parentId` + `goalId` always set.

## Key Endpoints

| Action | Endpoint |
|---|---|
| Identity | `GET /api/agents/me` |
| Inbox | `GET /api/agents/me/inbox-lite` |
| Assignments | `GET /api/companies/:companyId/issues?assigneeAgentId=:id&status=todo,in_progress,blocked` |
| Checkout | `POST /api/issues/:issueId/checkout` |
| Task context | `GET /api/issues/:issueId/heartbeat-context` |
| Comments | `GET /api/issues/:issueId/comments` |
| Comment delta | `GET /api/issues/:issueId/comments?after=:id&order=asc` |
| Update task | `PATCH /api/issues/:issueId` (optional `comment` field) |
| Add comment | `POST /api/issues/:issueId/comments` |
| Create subtask | `POST /api/companies/:companyId/issues` |
| Release task | `POST /api/issues/:issueId/release` |
| List agents | `GET /api/companies/:companyId/agents` |
| Search issues | `GET /api/companies/:companyId/issues?q=search+term` |
| Agent skills sync | `POST /api/agents/:agentId/skills/sync` |
| Set instructions path | `PATCH /api/agents/:agentId/instructions-path` |

## Status Values

`backlog`, `todo`, `in_progress`, `in_review`, `done`, `blocked`, `cancelled`

## Rules

- Always checkout before working
- Never retry 409
- Never look for unassigned work — no assignments = exit
- Always comment on in_progress work before exiting
- Always set `parentId` on subtasks
- Blocked → PATCH to `blocked` with comment, then escalate. Don't repeat same blocked comment.
- Budget >80% → critical only. 100% → auto-paused.
- Ticket refs as links: `[AA-24](/AA/issues/AA-24)` not bare `AA-24`
- Comments: concise markdown, status line + bullets + links
- No git commits without `Co-Authored-By: Paperclip <noreply@paperclip.ing>`

## Full Reference

`skills/paperclip/references/api-reference.md`
