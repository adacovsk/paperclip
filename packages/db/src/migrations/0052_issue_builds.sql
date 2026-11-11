CREATE TABLE "issue_builds" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"issue_id" uuid NOT NULL,
	"stage_issue_id" uuid,
	"exit_code" integer NOT NULL,
	"lane" text NOT NULL,
	"head_sha" text,
	"base_sha" text,
	"host" text,
	"action" text,
	"note" text,
	"finished_at" timestamp with time zone NOT NULL,
	"reported_by_agent_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "issue_builds" ADD CONSTRAINT "issue_builds_issue_id_issues_id_fk" FOREIGN KEY ("issue_id") REFERENCES "public"."issues"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "issue_builds" ADD CONSTRAINT "issue_builds_stage_issue_id_issues_id_fk" FOREIGN KEY ("stage_issue_id") REFERENCES "public"."issues"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "issue_builds" ADD CONSTRAINT "issue_builds_reported_by_agent_id_agents_id_fk" FOREIGN KEY ("reported_by_agent_id") REFERENCES "public"."agents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "issue_builds_issue_finished_idx" ON "issue_builds" USING btree ("issue_id","finished_at");--> statement-breakpoint
CREATE UNIQUE INDEX "issue_builds_result_uq" ON "issue_builds" USING btree ("issue_id","finished_at");