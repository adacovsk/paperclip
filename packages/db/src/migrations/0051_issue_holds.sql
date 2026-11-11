ALTER TABLE "issues" ADD COLUMN "hold" jsonb;--> statement-breakpoint
ALTER TABLE "issues" ADD COLUMN "released_hold" jsonb;--> statement-breakpoint
-- Tasks held before the column existed carry their hold only as a `Held:`
-- comment. Reading its release condition takes the same parser the server uses
-- for new comments, so they are marked here and read at the next boot
-- (`backfillHolds`), which leaves no marked row behind.
UPDATE "issues" SET "hold" = '{"kind":"pending_backfill"}'::jsonb
WHERE "status" = 'blocked'
  AND "assignee_agent_id" IS NULL
  AND "assignee_user_id" IS NULL
  AND EXISTS (
    SELECT 1 FROM "issue_comments" c
    WHERE c."issue_id" = "issues"."id" AND c."body" ~ '^\s*Held:'
  );
