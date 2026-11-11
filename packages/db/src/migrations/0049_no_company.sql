ALTER TABLE "instance_settings" ADD COLUMN "name" text DEFAULT 'Paperclip' NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "description" text;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "status" text DEFAULT 'active' NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "pause_reason" text;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "paused_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "issue_prefix" text DEFAULT 'PAP' NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "issue_counter" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "budget_monthly_cents" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "spent_monthly_cents" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "require_operator_approval_for_new_agents" boolean DEFAULT true NOT NULL;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "brand_color" text;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD COLUMN "logo_asset_id" uuid;
--> statement-breakpoint
ALTER TABLE "instance_settings" ADD CONSTRAINT "instance_settings_logo_asset_id_assets_id_fk" FOREIGN KEY ("logo_asset_id") REFERENCES "public"."assets"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
-- The company level is removed: one instance is the top-level container.
-- Carry the single company's own fields onto the instance_settings singleton
-- before anything that references companies is dropped.
INSERT INTO "instance_settings" ("singleton_key") VALUES ('default') ON CONFLICT ("singleton_key") DO NOTHING;
--> statement-breakpoint
UPDATE "instance_settings" AS s SET
  "name" = c."name",
  "description" = c."description",
  "status" = CASE WHEN c."status" = 'paused' THEN 'paused' ELSE 'active' END,
  "pause_reason" = c."pause_reason",
  "paused_at" = c."paused_at",
  "issue_prefix" = c."issue_prefix",
  "issue_counter" = c."issue_counter",
  "budget_monthly_cents" = c."budget_monthly_cents",
  "spent_monthly_cents" = c."spent_monthly_cents",
  "require_operator_approval_for_new_agents" = c."require_operator_approval_for_new_agents",
  "brand_color" = c."brand_color",
  "logo_asset_id" = (SELECT l."asset_id" FROM "company_logos" l WHERE l."company_id" = c."id" LIMIT 1),
  "updated_at" = now()
FROM (SELECT * FROM "companies" ORDER BY "created_at" LIMIT 1) AS c
WHERE s."singleton_key" = 'default';
--> statement-breakpoint
UPDATE "goals" SET "level" = 'instance' WHERE "level" = 'company';
--> statement-breakpoint
UPDATE "budget_policies" SET "scope_type" = 'instance', "scope_id" = (SELECT "id" FROM "instance_settings" WHERE "singleton_key" = 'default') WHERE "scope_type" = 'company';
--> statement-breakpoint
UPDATE "budget_incidents" SET "scope_type" = 'instance', "scope_id" = (SELECT "id" FROM "instance_settings" WHERE "singleton_key" = 'default') WHERE "scope_type" = 'company';
--> statement-breakpoint
UPDATE "invites" SET "invite_type" = 'join' WHERE "invite_type" = 'company_join';
--> statement-breakpoint
DELETE FROM "plugin_state" WHERE "scope_kind" = 'company';
--> statement-breakpoint
ALTER TABLE "activity_log" DROP CONSTRAINT "activity_log_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agent_api_keys" DROP CONSTRAINT "agent_api_keys_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agent_config_revisions" DROP CONSTRAINT "agent_config_revisions_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agent_runtime_state" DROP CONSTRAINT "agent_runtime_state_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agent_task_sessions" DROP CONSTRAINT "agent_task_sessions_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agent_wakeup_requests" DROP CONSTRAINT "agent_wakeup_requests_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "agents" DROP CONSTRAINT "agents_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "approval_comments" DROP CONSTRAINT "approval_comments_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "approvals" DROP CONSTRAINT "approvals_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "assets" DROP CONSTRAINT "assets_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "budget_incidents" DROP CONSTRAINT "budget_incidents_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "budget_policies" DROP CONSTRAINT "budget_policies_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "cli_auth_challenges" DROP CONSTRAINT "cli_auth_challenges_requested_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "company_memberships" DROP CONSTRAINT "company_memberships_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "company_secrets" DROP CONSTRAINT "company_secrets_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "company_skills" DROP CONSTRAINT "company_skills_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "cost_events" DROP CONSTRAINT "cost_events_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "document_revisions" DROP CONSTRAINT "document_revisions_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "documents" DROP CONSTRAINT "documents_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "execution_workspaces" DROP CONSTRAINT "execution_workspaces_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "finance_events" DROP CONSTRAINT "finance_events_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "goals" DROP CONSTRAINT "goals_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "heartbeat_run_events" DROP CONSTRAINT "heartbeat_run_events_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "heartbeat_runs" DROP CONSTRAINT "heartbeat_runs_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "invites" DROP CONSTRAINT "invites_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_approvals" DROP CONSTRAINT "issue_approvals_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_attachments" DROP CONSTRAINT "issue_attachments_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_comments" DROP CONSTRAINT "issue_comments_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_documents" DROP CONSTRAINT "issue_documents_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_inbox_archives" DROP CONSTRAINT "issue_inbox_archives_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_labels" DROP CONSTRAINT "issue_labels_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_read_states" DROP CONSTRAINT "issue_read_states_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issue_work_products" DROP CONSTRAINT "issue_work_products_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "issues" DROP CONSTRAINT "issues_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "join_requests" DROP CONSTRAINT "join_requests_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "labels" DROP CONSTRAINT "labels_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "principal_permission_grants" DROP CONSTRAINT "principal_permission_grants_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "project_goals" DROP CONSTRAINT "project_goals_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "project_workspaces" DROP CONSTRAINT "project_workspaces_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "projects" DROP CONSTRAINT "projects_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "routine_runs" DROP CONSTRAINT "routine_runs_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "routine_triggers" DROP CONSTRAINT "routine_triggers_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "routines" DROP CONSTRAINT "routines_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "workspace_operations" DROP CONSTRAINT "workspace_operations_company_id_companies_id_fk";
--> statement-breakpoint
ALTER TABLE "workspace_runtime_services" DROP CONSTRAINT "workspace_runtime_services_company_id_companies_id_fk";
--> statement-breakpoint
DROP INDEX "activity_log_company_created_idx";
--> statement-breakpoint
DROP INDEX "agent_api_keys_company_agent_idx";
--> statement-breakpoint
DROP INDEX "agent_config_revisions_company_agent_created_idx";
--> statement-breakpoint
DROP INDEX "agent_runtime_state_company_agent_idx";
--> statement-breakpoint
DROP INDEX "agent_runtime_state_company_updated_idx";
--> statement-breakpoint
DROP INDEX "agent_task_sessions_company_agent_adapter_task_uniq";
--> statement-breakpoint
DROP INDEX "agent_task_sessions_company_agent_updated_idx";
--> statement-breakpoint
DROP INDEX "agent_task_sessions_company_task_updated_idx";
--> statement-breakpoint
DROP INDEX "agent_wakeup_requests_company_agent_status_idx";
--> statement-breakpoint
DROP INDEX "agent_wakeup_requests_company_requested_idx";
--> statement-breakpoint
DROP INDEX "agents_company_status_idx";
--> statement-breakpoint
DROP INDEX "agents_company_reports_to_idx";
--> statement-breakpoint
DROP INDEX "approval_comments_company_idx";
--> statement-breakpoint
DROP INDEX "approvals_company_status_type_idx";
--> statement-breakpoint
DROP INDEX "assets_company_created_idx";
--> statement-breakpoint
DROP INDEX "assets_company_provider_idx";
--> statement-breakpoint
DROP INDEX "assets_company_object_key_uq";
--> statement-breakpoint
DROP INDEX "budget_incidents_company_status_idx";
--> statement-breakpoint
DROP INDEX "budget_incidents_company_scope_idx";
--> statement-breakpoint
DROP INDEX "budget_policies_company_scope_active_idx";
--> statement-breakpoint
DROP INDEX "budget_policies_company_window_idx";
--> statement-breakpoint
DROP INDEX "budget_policies_company_scope_metric_unique_idx";
--> statement-breakpoint
DROP INDEX "cli_auth_challenges_requested_company_idx";
--> statement-breakpoint
DROP INDEX "company_memberships_company_principal_unique_idx";
--> statement-breakpoint
DROP INDEX "company_memberships_principal_status_idx";
--> statement-breakpoint
DROP INDEX "company_memberships_company_status_idx";
--> statement-breakpoint
DROP INDEX "company_secret_versions_secret_idx";
--> statement-breakpoint
DROP INDEX "company_secret_versions_value_sha256_idx";
--> statement-breakpoint
DROP INDEX "company_secret_versions_secret_version_uq";
--> statement-breakpoint
DROP INDEX "company_secrets_company_idx";
--> statement-breakpoint
DROP INDEX "company_secrets_company_provider_idx";
--> statement-breakpoint
DROP INDEX "company_secrets_company_name_uq";
--> statement-breakpoint
DROP INDEX "company_skills_company_key_idx";
--> statement-breakpoint
DROP INDEX "company_skills_company_name_idx";
--> statement-breakpoint
DROP INDEX "cost_events_company_occurred_idx";
--> statement-breakpoint
DROP INDEX "cost_events_company_agent_occurred_idx";
--> statement-breakpoint
DROP INDEX "cost_events_company_provider_occurred_idx";
--> statement-breakpoint
DROP INDEX "cost_events_company_biller_occurred_idx";
--> statement-breakpoint
DROP INDEX "cost_events_company_heartbeat_run_idx";
--> statement-breakpoint
DROP INDEX "document_revisions_company_document_created_idx";
--> statement-breakpoint
DROP INDEX "documents_company_updated_idx";
--> statement-breakpoint
DROP INDEX "documents_company_created_idx";
--> statement-breakpoint
DROP INDEX "execution_workspaces_company_project_status_idx";
--> statement-breakpoint
DROP INDEX "execution_workspaces_company_project_workspace_status_idx";
--> statement-breakpoint
DROP INDEX "execution_workspaces_company_source_issue_idx";
--> statement-breakpoint
DROP INDEX "execution_workspaces_company_last_used_idx";
--> statement-breakpoint
DROP INDEX "execution_workspaces_company_branch_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_occurred_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_biller_occurred_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_kind_occurred_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_direction_occurred_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_heartbeat_run_idx";
--> statement-breakpoint
DROP INDEX "finance_events_company_cost_event_idx";
--> statement-breakpoint
DROP INDEX "goals_company_idx";
--> statement-breakpoint
DROP INDEX "heartbeat_run_events_company_run_idx";
--> statement-breakpoint
DROP INDEX "heartbeat_run_events_company_created_idx";
--> statement-breakpoint
DROP INDEX "heartbeat_runs_company_agent_started_idx";
--> statement-breakpoint
DROP INDEX "heartbeat_runs_company_created_idx";
--> statement-breakpoint
DROP INDEX "heartbeat_runs_company_agent_created_idx";
--> statement-breakpoint
DROP INDEX "invites_company_invite_state_idx";
--> statement-breakpoint
DROP INDEX "issue_approvals_company_idx";
--> statement-breakpoint
DROP INDEX "issue_attachments_company_issue_idx";
--> statement-breakpoint
DROP INDEX "issue_comments_company_idx";
--> statement-breakpoint
DROP INDEX "issue_comments_company_issue_created_at_idx";
--> statement-breakpoint
DROP INDEX "issue_comments_company_author_issue_created_at_idx";
--> statement-breakpoint
DROP INDEX "issue_documents_company_issue_key_uq";
--> statement-breakpoint
DROP INDEX "issue_documents_company_issue_updated_idx";
--> statement-breakpoint
DROP INDEX "issue_inbox_archives_company_issue_idx";
--> statement-breakpoint
DROP INDEX "issue_inbox_archives_company_user_idx";
--> statement-breakpoint
DROP INDEX "issue_inbox_archives_company_issue_user_idx";
--> statement-breakpoint
DROP INDEX "issue_labels_company_idx";
--> statement-breakpoint
DROP INDEX "issue_read_states_company_issue_idx";
--> statement-breakpoint
DROP INDEX "issue_read_states_company_user_idx";
--> statement-breakpoint
DROP INDEX "issue_read_states_company_issue_user_idx";
--> statement-breakpoint
DROP INDEX "issue_work_products_company_issue_type_idx";
--> statement-breakpoint
DROP INDEX "issue_work_products_company_execution_workspace_type_idx";
--> statement-breakpoint
DROP INDEX "issue_work_products_company_provider_external_id_idx";
--> statement-breakpoint
DROP INDEX "issue_work_products_company_updated_idx";
--> statement-breakpoint
DROP INDEX "issues_company_status_idx";
--> statement-breakpoint
DROP INDEX "issues_company_assignee_status_idx";
--> statement-breakpoint
DROP INDEX "issues_company_assignee_user_status_idx";
--> statement-breakpoint
DROP INDEX "issues_company_parent_idx";
--> statement-breakpoint
DROP INDEX "issues_company_project_idx";
--> statement-breakpoint
DROP INDEX "issues_company_origin_idx";
--> statement-breakpoint
DROP INDEX "issues_company_project_workspace_idx";
--> statement-breakpoint
DROP INDEX "issues_company_execution_workspace_idx";
--> statement-breakpoint
DROP INDEX "join_requests_company_status_type_created_idx";
--> statement-breakpoint
DROP INDEX "labels_company_idx";
--> statement-breakpoint
DROP INDEX "labels_company_name_idx";
--> statement-breakpoint
DROP INDEX "principal_permission_grants_company_permission_idx";
--> statement-breakpoint
DROP INDEX "project_goals_company_idx";
--> statement-breakpoint
DROP INDEX "project_workspaces_company_project_idx";
--> statement-breakpoint
DROP INDEX "project_workspaces_company_shared_key_idx";
--> statement-breakpoint
DROP INDEX "projects_company_idx";
--> statement-breakpoint
DROP INDEX "routine_runs_company_routine_idx";
--> statement-breakpoint
DROP INDEX "routine_triggers_company_routine_idx";
--> statement-breakpoint
DROP INDEX "routine_triggers_company_kind_idx";
--> statement-breakpoint
DROP INDEX "routines_company_status_idx";
--> statement-breakpoint
DROP INDEX "routines_company_assignee_idx";
--> statement-breakpoint
DROP INDEX "routines_company_project_idx";
--> statement-breakpoint
DROP INDEX "workspace_operations_company_run_started_idx";
--> statement-breakpoint
DROP INDEX "workspace_operations_company_workspace_started_idx";
--> statement-breakpoint
DROP INDEX "workspace_runtime_services_company_workspace_status_idx";
--> statement-breakpoint
DROP INDEX "workspace_runtime_services_company_execution_workspace_status_idx";
--> statement-breakpoint
DROP INDEX "workspace_runtime_services_company_project_status_idx";
--> statement-breakpoint
DROP INDEX "workspace_runtime_services_company_updated_idx";
--> statement-breakpoint
DROP INDEX "issues_open_routine_execution_uq";
--> statement-breakpoint
DROP INDEX "principal_permission_grants_unique_idx";
--> statement-breakpoint
ALTER TABLE "activity_log" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agent_api_keys" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agent_config_revisions" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agent_runtime_state" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agent_task_sessions" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agent_wakeup_requests" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "agents" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "approval_comments" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "approvals" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "assets" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "budget_incidents" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "budget_policies" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "cli_auth_challenges" DROP COLUMN "requested_company_id";
--> statement-breakpoint
ALTER TABLE "company_memberships" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "company_secrets" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "company_skills" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "cost_events" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "document_revisions" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "documents" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "execution_workspaces" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "finance_events" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "goals" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "heartbeat_run_events" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "heartbeat_runs" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "invites" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_approvals" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_attachments" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_comments" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_documents" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_inbox_archives" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_labels" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_read_states" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issue_work_products" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "issues" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "join_requests" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "labels" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "principal_permission_grants" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "project_goals" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "project_workspaces" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "projects" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "routine_runs" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "routine_triggers" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "routines" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "workspace_operations" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "workspace_runtime_services" DROP COLUMN "company_id";
--> statement-breakpoint
ALTER TABLE "companies" DISABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "company_logos" DISABLE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "plugin_company_settings" DISABLE ROW LEVEL SECURITY;
--> statement-breakpoint
DROP TABLE "companies" CASCADE;
--> statement-breakpoint
DROP TABLE "company_logos" CASCADE;
--> statement-breakpoint
DROP TABLE "plugin_company_settings" CASCADE;
--> statement-breakpoint
CREATE INDEX "activity_log_created_idx" ON "activity_log" USING btree ("created_at");
--> statement-breakpoint
CREATE INDEX "agent_api_keys_agent_idx" ON "agent_api_keys" USING btree ("agent_id");
--> statement-breakpoint
CREATE INDEX "agent_runtime_state_agent_idx" ON "agent_runtime_state" USING btree ("agent_id");
--> statement-breakpoint
CREATE INDEX "agent_runtime_state_updated_idx" ON "agent_runtime_state" USING btree ("updated_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "agent_task_sessions_agent_adapter_task_uniq" ON "agent_task_sessions" USING btree ("agent_id","adapter_type","task_key");
--> statement-breakpoint
CREATE INDEX "agent_task_sessions_agent_updated_idx" ON "agent_task_sessions" USING btree ("agent_id","updated_at");
--> statement-breakpoint
CREATE INDEX "agent_task_sessions_task_updated_idx" ON "agent_task_sessions" USING btree ("task_key","updated_at");
--> statement-breakpoint
CREATE INDEX "agent_wakeup_requests_agent_status_idx" ON "agent_wakeup_requests" USING btree ("agent_id","status");
--> statement-breakpoint
CREATE INDEX "agent_wakeup_requests_requested_idx" ON "agent_wakeup_requests" USING btree ("requested_at");
--> statement-breakpoint
CREATE INDEX "agents_status_idx" ON "agents" USING btree ("status");
--> statement-breakpoint
CREATE INDEX "agents_reports_to_idx" ON "agents" USING btree ("reports_to");
--> statement-breakpoint
CREATE INDEX "approvals_status_type_idx" ON "approvals" USING btree ("status","type");
--> statement-breakpoint
CREATE INDEX "assets_created_idx" ON "assets" USING btree ("created_at");
--> statement-breakpoint
CREATE INDEX "assets_provider_idx" ON "assets" USING btree ("provider");
--> statement-breakpoint
CREATE UNIQUE INDEX "assets_object_key_uq" ON "assets" USING btree ("object_key");
--> statement-breakpoint
CREATE INDEX "budget_incidents_status_idx" ON "budget_incidents" USING btree ("status");
--> statement-breakpoint
CREATE INDEX "budget_incidents_scope_idx" ON "budget_incidents" USING btree ("scope_type","scope_id","status");
--> statement-breakpoint
CREATE INDEX "budget_policies_scope_active_idx" ON "budget_policies" USING btree ("scope_type","scope_id","is_active");
--> statement-breakpoint
CREATE INDEX "budget_policies_window_idx" ON "budget_policies" USING btree ("window_kind","metric");
--> statement-breakpoint
CREATE UNIQUE INDEX "budget_policies_scope_metric_unique_idx" ON "budget_policies" USING btree ("scope_type","scope_id","metric","window_kind");
--> statement-breakpoint
CREATE UNIQUE INDEX "memberships_principal_unique_idx" ON "company_memberships" USING btree ("principal_type","principal_id");
--> statement-breakpoint
CREATE INDEX "memberships_principal_status_idx" ON "company_memberships" USING btree ("principal_type","principal_id","status");
--> statement-breakpoint
CREATE INDEX "memberships_status_idx" ON "company_memberships" USING btree ("status");
--> statement-breakpoint
CREATE INDEX "secret_versions_secret_idx" ON "company_secret_versions" USING btree ("secret_id","created_at");
--> statement-breakpoint
CREATE INDEX "secret_versions_value_sha256_idx" ON "company_secret_versions" USING btree ("value_sha256");
--> statement-breakpoint
CREATE UNIQUE INDEX "secret_versions_secret_version_uq" ON "company_secret_versions" USING btree ("secret_id","version");
--> statement-breakpoint
CREATE INDEX "secrets_provider_idx" ON "company_secrets" USING btree ("provider");
--> statement-breakpoint
CREATE UNIQUE INDEX "secrets_name_uq" ON "company_secrets" USING btree ("name");
--> statement-breakpoint
CREATE UNIQUE INDEX "skills_key_idx" ON "company_skills" USING btree ("key");
--> statement-breakpoint
CREATE INDEX "skills_name_idx" ON "company_skills" USING btree ("name");
--> statement-breakpoint
CREATE INDEX "cost_events_occurred_idx" ON "cost_events" USING btree ("occurred_at");
--> statement-breakpoint
CREATE INDEX "cost_events_agent_occurred_idx" ON "cost_events" USING btree ("agent_id","occurred_at");
--> statement-breakpoint
CREATE INDEX "cost_events_provider_occurred_idx" ON "cost_events" USING btree ("provider","occurred_at");
--> statement-breakpoint
CREATE INDEX "cost_events_biller_occurred_idx" ON "cost_events" USING btree ("biller","occurred_at");
--> statement-breakpoint
CREATE INDEX "cost_events_heartbeat_run_idx" ON "cost_events" USING btree ("heartbeat_run_id");
--> statement-breakpoint
CREATE INDEX "document_revisions_document_created_idx" ON "document_revisions" USING btree ("document_id","created_at");
--> statement-breakpoint
CREATE INDEX "documents_updated_idx" ON "documents" USING btree ("updated_at");
--> statement-breakpoint
CREATE INDEX "documents_created_idx" ON "documents" USING btree ("created_at");
--> statement-breakpoint
CREATE INDEX "execution_workspaces_project_status_idx" ON "execution_workspaces" USING btree ("project_id","status");
--> statement-breakpoint
CREATE INDEX "execution_workspaces_project_workspace_status_idx" ON "execution_workspaces" USING btree ("project_workspace_id","status");
--> statement-breakpoint
CREATE INDEX "execution_workspaces_source_issue_idx" ON "execution_workspaces" USING btree ("source_issue_id");
--> statement-breakpoint
CREATE INDEX "execution_workspaces_last_used_idx" ON "execution_workspaces" USING btree ("last_used_at");
--> statement-breakpoint
CREATE INDEX "execution_workspaces_branch_idx" ON "execution_workspaces" USING btree ("branch_name");
--> statement-breakpoint
CREATE INDEX "finance_events_occurred_idx" ON "finance_events" USING btree ("occurred_at");
--> statement-breakpoint
CREATE INDEX "finance_events_biller_occurred_idx" ON "finance_events" USING btree ("biller","occurred_at");
--> statement-breakpoint
CREATE INDEX "finance_events_kind_occurred_idx" ON "finance_events" USING btree ("event_kind","occurred_at");
--> statement-breakpoint
CREATE INDEX "finance_events_direction_occurred_idx" ON "finance_events" USING btree ("direction","occurred_at");
--> statement-breakpoint
CREATE INDEX "finance_events_heartbeat_run_idx" ON "finance_events" USING btree ("heartbeat_run_id");
--> statement-breakpoint
CREATE INDEX "finance_events_cost_event_idx" ON "finance_events" USING btree ("cost_event_id");
--> statement-breakpoint
CREATE INDEX "heartbeat_run_events_run_idx" ON "heartbeat_run_events" USING btree ("run_id");
--> statement-breakpoint
CREATE INDEX "heartbeat_run_events_created_idx" ON "heartbeat_run_events" USING btree ("created_at");
--> statement-breakpoint
CREATE INDEX "heartbeat_runs_agent_started_idx" ON "heartbeat_runs" USING btree ("agent_id","started_at");
--> statement-breakpoint
CREATE INDEX "heartbeat_runs_created_idx" ON "heartbeat_runs" USING btree ("created_at" DESC NULLS LAST);
--> statement-breakpoint
CREATE INDEX "heartbeat_runs_agent_created_idx" ON "heartbeat_runs" USING btree ("agent_id","created_at" DESC NULLS LAST);
--> statement-breakpoint
CREATE INDEX "invites_invite_state_idx" ON "invites" USING btree ("invite_type","revoked_at","expires_at");
--> statement-breakpoint
CREATE INDEX "issue_attachments_issue_idx" ON "issue_attachments" USING btree ("issue_id");
--> statement-breakpoint
CREATE INDEX "issue_comments_issue_created_at_idx" ON "issue_comments" USING btree ("issue_id","created_at");
--> statement-breakpoint
CREATE INDEX "issue_comments_author_issue_created_at_idx" ON "issue_comments" USING btree ("author_user_id","issue_id","created_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "issue_documents_issue_key_uq" ON "issue_documents" USING btree ("issue_id","key");
--> statement-breakpoint
CREATE INDEX "issue_documents_issue_updated_idx" ON "issue_documents" USING btree ("issue_id","updated_at");
--> statement-breakpoint
CREATE INDEX "issue_inbox_archives_issue_idx" ON "issue_inbox_archives" USING btree ("issue_id");
--> statement-breakpoint
CREATE INDEX "issue_inbox_archives_user_idx" ON "issue_inbox_archives" USING btree ("user_id");
--> statement-breakpoint
CREATE UNIQUE INDEX "issue_inbox_archives_issue_user_idx" ON "issue_inbox_archives" USING btree ("issue_id","user_id");
--> statement-breakpoint
CREATE INDEX "issue_read_states_issue_idx" ON "issue_read_states" USING btree ("issue_id");
--> statement-breakpoint
CREATE INDEX "issue_read_states_user_idx" ON "issue_read_states" USING btree ("user_id");
--> statement-breakpoint
CREATE UNIQUE INDEX "issue_read_states_issue_user_idx" ON "issue_read_states" USING btree ("issue_id","user_id");
--> statement-breakpoint
CREATE INDEX "issue_work_products_issue_type_idx" ON "issue_work_products" USING btree ("issue_id","type");
--> statement-breakpoint
CREATE INDEX "issue_work_products_execution_workspace_type_idx" ON "issue_work_products" USING btree ("execution_workspace_id","type");
--> statement-breakpoint
CREATE INDEX "issue_work_products_provider_external_id_idx" ON "issue_work_products" USING btree ("provider","external_id");
--> statement-breakpoint
CREATE INDEX "issue_work_products_updated_idx" ON "issue_work_products" USING btree ("updated_at");
--> statement-breakpoint
CREATE INDEX "issues_status_idx" ON "issues" USING btree ("status");
--> statement-breakpoint
CREATE INDEX "issues_assignee_status_idx" ON "issues" USING btree ("assignee_agent_id","status");
--> statement-breakpoint
CREATE INDEX "issues_assignee_user_status_idx" ON "issues" USING btree ("assignee_user_id","status");
--> statement-breakpoint
CREATE INDEX "issues_parent_idx" ON "issues" USING btree ("parent_id");
--> statement-breakpoint
CREATE INDEX "issues_project_idx" ON "issues" USING btree ("project_id");
--> statement-breakpoint
CREATE INDEX "issues_origin_idx" ON "issues" USING btree ("origin_kind","origin_id");
--> statement-breakpoint
CREATE INDEX "issues_project_workspace_idx" ON "issues" USING btree ("project_workspace_id");
--> statement-breakpoint
CREATE INDEX "issues_execution_workspace_idx" ON "issues" USING btree ("execution_workspace_id");
--> statement-breakpoint
CREATE INDEX "join_requests_status_type_created_idx" ON "join_requests" USING btree ("status","request_type","created_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "labels_name_idx" ON "labels" USING btree ("name");
--> statement-breakpoint
CREATE INDEX "principal_permission_grants_permission_idx" ON "principal_permission_grants" USING btree ("permission_key");
--> statement-breakpoint
CREATE INDEX "project_workspaces_project_idx" ON "project_workspaces" USING btree ("project_id");
--> statement-breakpoint
CREATE INDEX "project_workspaces_shared_key_idx" ON "project_workspaces" USING btree ("shared_workspace_key");
--> statement-breakpoint
CREATE INDEX "routine_runs_routine_idx" ON "routine_runs" USING btree ("routine_id","created_at");
--> statement-breakpoint
CREATE INDEX "routine_triggers_routine_idx" ON "routine_triggers" USING btree ("routine_id");
--> statement-breakpoint
CREATE INDEX "routine_triggers_kind_idx" ON "routine_triggers" USING btree ("kind");
--> statement-breakpoint
CREATE INDEX "routines_status_idx" ON "routines" USING btree ("status");
--> statement-breakpoint
CREATE INDEX "routines_assignee_idx" ON "routines" USING btree ("assignee_agent_id");
--> statement-breakpoint
CREATE INDEX "routines_project_idx" ON "routines" USING btree ("project_id");
--> statement-breakpoint
CREATE INDEX "workspace_operations_run_started_idx" ON "workspace_operations" USING btree ("heartbeat_run_id","started_at");
--> statement-breakpoint
CREATE INDEX "workspace_operations_workspace_started_idx" ON "workspace_operations" USING btree ("execution_workspace_id","started_at");
--> statement-breakpoint
CREATE INDEX "workspace_runtime_services_workspace_status_idx" ON "workspace_runtime_services" USING btree ("project_workspace_id","status");
--> statement-breakpoint
CREATE INDEX "workspace_runtime_services_execution_workspace_status_idx" ON "workspace_runtime_services" USING btree ("execution_workspace_id","status");
--> statement-breakpoint
CREATE INDEX "workspace_runtime_services_project_status_idx" ON "workspace_runtime_services" USING btree ("project_id","status");
--> statement-breakpoint
CREATE INDEX "workspace_runtime_services_updated_idx" ON "workspace_runtime_services" USING btree ("updated_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "issues_open_routine_execution_uq" ON "issues" USING btree ("origin_kind","origin_id") WHERE "issues"."origin_kind" = 'routine_execution'
          and "issues"."origin_id" is not null
          and "issues"."hidden_at" is null
          and "issues"."execution_run_id" is not null
          and "issues"."status" in ('backlog', 'todo', 'in_progress', 'in_review', 'blocked');
--> statement-breakpoint
CREATE UNIQUE INDEX "principal_permission_grants_unique_idx" ON "principal_permission_grants" USING btree ("principal_type","principal_id","permission_key");
--> statement-breakpoint
ALTER TABLE "company_memberships" RENAME TO "memberships";
--> statement-breakpoint
ALTER TABLE "company_secrets" RENAME TO "secrets";
--> statement-breakpoint
ALTER TABLE "company_secret_versions" RENAME TO "secret_versions";
--> statement-breakpoint
ALTER TABLE "company_skills" RENAME TO "skills";
--> statement-breakpoint
ALTER INDEX "company_memberships_pkey" RENAME TO "memberships_pkey";
--> statement-breakpoint
ALTER INDEX "company_secrets_pkey" RENAME TO "secrets_pkey";
--> statement-breakpoint
ALTER INDEX "company_secret_versions_pkey" RENAME TO "secret_versions_pkey";
--> statement-breakpoint
ALTER INDEX "company_skills_pkey" RENAME TO "skills_pkey";
--> statement-breakpoint
ALTER TABLE "routine_triggers" RENAME CONSTRAINT "routine_triggers_secret_id_company_secrets_id_fk" TO "routine_triggers_secret_id_secrets_id_fk";
--> statement-breakpoint
ALTER TABLE "secret_versions" RENAME CONSTRAINT "company_secret_versions_secret_id_company_secrets_id_fk" TO "secret_versions_secret_id_secrets_id_fk";
--> statement-breakpoint
ALTER TABLE "secret_versions" RENAME CONSTRAINT "company_secret_versions_created_by_agent_id_agents_id_fk" TO "secret_versions_created_by_agent_id_agents_id_fk";
--> statement-breakpoint
ALTER TABLE "secrets" RENAME CONSTRAINT "company_secrets_created_by_agent_id_agents_id_fk" TO "secrets_created_by_agent_id_agents_id_fk";
--> statement-breakpoint
ALTER TABLE "invites" ALTER COLUMN "invite_type" SET DEFAULT 'join';
