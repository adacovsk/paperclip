# Heartbeat Checklist

Use `paperclip` skill for all API. Never raw curl.

1. **Context**: check `PAPERCLIP_TASK_ID`, `PAPERCLIP_WAKE_REASON`, `PAPERCLIP_WAKE_COMMENT_ID`. Subtask wake → advance pipeline first.
2. **Inbox**: paperclip skill. `in_progress` first, then `todo`. Skip `blocked` unless unblockable. 409 = someone else owns it, move on.
3. **Checkout** before working. Paperclip skill.
4. **Work**: advance pipeline, create tasks, unblock agents.
5. **Delegate**: subtasks via paperclip skill. Always set `parentId`+`goalId`. `paperclip-create-agent` to hire.
6. **Exit**: comment on in_progress work. Nothing to do → exit clean.

## Responsibilities

Prioritize from roadmap. Hire agents when needed. Unblock agents. Budget >80% → critical only.
Never cancel cross-agent tasks — reassign with comment. Only work on assignments, don't look for unassigned work.
