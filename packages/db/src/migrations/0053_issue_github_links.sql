CREATE TABLE "issue_github_links" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"issue_id" uuid NOT NULL,
	"repo" text NOT NULL,
	"number" integer NOT NULL,
	"linked_by_agent_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "issue_github_links" ADD CONSTRAINT "issue_github_links_issue_id_issues_id_fk" FOREIGN KEY ("issue_id") REFERENCES "public"."issues"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "issue_github_links" ADD CONSTRAINT "issue_github_links_linked_by_agent_id_agents_id_fk" FOREIGN KEY ("linked_by_agent_id") REFERENCES "public"."agents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "issue_github_links_uq" ON "issue_github_links" USING btree ("issue_id","repo","number");--> statement-breakpoint
CREATE INDEX "issue_github_links_repo_number_idx" ON "issue_github_links" USING btree ("repo","number");