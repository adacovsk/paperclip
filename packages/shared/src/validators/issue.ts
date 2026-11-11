import { z } from "zod";
import { patchSchema } from "./patch.js";
import { ISSUE_PRIORITIES, ISSUE_STATUSES } from "../constants.js";
import { ISSUE_HOLD_BLOCKER_KINDS, ISSUE_HOLD_KINDS } from "../issue-hold.js";
import { ISSUE_BUILD_LANES } from "../issue-build.js";

const executionWorkspaceStrategySchema = z
  .object({
    type: z.enum(["project_primary", "git_worktree", "adapter_managed", "cloud_sandbox"]).optional(),
    baseRef: z.string().optional().nullable(),
    branchTemplate: z.string().optional().nullable(),
    worktreeParentDir: z.string().optional().nullable(),
    provisionCommand: z.string().optional().nullable(),
    teardownCommand: z.string().optional().nullable(),
  })
  .strict();

export const issueExecutionWorkspaceSettingsSchema = z
  .object({
    mode: z.enum(["inherit", "shared_workspace", "isolated_workspace", "operator_branch", "reuse_existing", "agent_default"]).optional(),
    workspaceStrategy: executionWorkspaceStrategySchema.optional().nullable(),
    workspaceRuntime: z.record(z.string(), z.unknown()).optional().nullable(),
  })
  .strict();

export const issueAssigneeAdapterOverridesSchema = z
  .object({
    adapterConfig: z.record(z.string(), z.unknown()).optional(),
    useProjectWorkspace: z.boolean().optional(),
  })
  .strict();

export const createIssueSchema = z.object({
  projectId: z.string().uuid().optional().nullable(),
  projectWorkspaceId: z.string().uuid().optional().nullable(),
  goalId: z.string().uuid().optional().nullable(),
  parentId: z.string().uuid().optional().nullable(),
  dedupeKey: z
    .string()
    .trim()
    .min(1)
    .max(64)
    .regex(/^[a-z0-9][a-z0-9_-]*$/, "dedupeKey must be lowercase letters, numbers, _ or -")
    .optional()
    .nullable(),
  title: z.string().min(1),
  description: z.string().optional().nullable(),
  // No default here on purpose. `backlog` is only a deferral for an assignee
  // that comes back on its own, so the right default depends on the assignee's
  // trigger config — which this schema cannot see. The create route resolves it
  // (server/src/routes/issues.ts); an explicit status from the caller always
  // wins, and the `backlog` column default still covers non-HTTP callers.
  status: z.enum(ISSUE_STATUSES).optional(),
  priority: z.enum(ISSUE_PRIORITIES).optional().default("medium"),
  assigneeAgentId: z.string().uuid().optional().nullable(),
  assigneeUserId: z.string().optional().nullable(),
  requestDepth: z.number().int().nonnegative().optional().default(0),
  billingCode: z.string().optional().nullable(),
  assigneeAdapterOverrides: issueAssigneeAdapterOverridesSchema.optional().nullable(),
  executionWorkspaceId: z.string().uuid().optional().nullable(),
  executionWorkspacePreference: z.enum([
    "inherit",
    "shared_workspace",
    "isolated_workspace",
    "operator_branch",
    "reuse_existing",
    "agent_default",
  ]).optional().nullable(),
  executionWorkspaceSettings: issueExecutionWorkspaceSettingsSchema.optional().nullable(),
  labelIds: z.array(z.string().uuid()).optional(),
});

export type CreateIssue = z.infer<typeof createIssueSchema>;

export const createIssueLabelSchema = z.object({
  name: z.string().trim().min(1).max(48),
  color: z.string().regex(/^#(?:[0-9a-fA-F]{6})$/, "Color must be a 6-digit hex value"),
});

export type CreateIssueLabel = z.infer<typeof createIssueLabelSchema>;

/**
 * A hold as a caller writes it. Blockers are named by issue id or identifier
 * (`AA-123`); the server resolves them and rejects one that does not exist.
 */
export const issueHoldInputSchema = z
  .object({
    kind: z.enum(ISSUE_HOLD_KINDS),
    blockers: z.array(z.string().trim().min(1)).max(20).optional().default([]),
    note: z.string().trim().max(500).optional().nullable(),
  })
  .superRefine((hold, ctx) => {
    const needsBlockers = ISSUE_HOLD_BLOCKER_KINDS.includes(hold.kind);
    if (needsBlockers && hold.blockers.length === 0) {
      ctx.addIssue({ code: "custom", path: ["blockers"], message: `A ${hold.kind} hold names the tasks it waits on` });
    }
    if (!needsBlockers && hold.blockers.length > 0) {
      ctx.addIssue({ code: "custom", path: ["blockers"], message: `A ${hold.kind} hold waits on no task` });
    }
    if (hold.kind === "other" && !hold.note) {
      ctx.addIssue({ code: "custom", path: ["note"], message: "A hold of kind other says why in its note" });
    }
  });

export type IssueHoldInput = z.infer<typeof issueHoldInputSchema>;

/** A build result as a reporter writes it. `finishedAt` identifies the result. */
export const reportIssueBuildSchema = z.object({
  exitCode: z.number().int().min(0).max(255),
  lane: z.enum(ISSUE_BUILD_LANES),
  finishedAt: z.string().datetime(),
  stageIssueId: z.string().uuid().optional().nullable(),
  headSha: z.string().trim().regex(/^[0-9a-f]{7,40}$/, "headSha is a git commit id").optional().nullable(),
  baseSha: z.string().trim().regex(/^[0-9a-f]{7,40}$/, "baseSha is a git commit id").optional().nullable(),
  host: z.string().trim().min(1).max(200).optional().nullable(),
  action: z.string().trim().min(1).max(40).optional().nullable(),
  note: z.string().trim().max(1000).optional().nullable(),
});

export type ReportIssueBuild = z.infer<typeof reportIssueBuildSchema>;

export const updateIssueSchema = patchSchema(createIssueSchema).extend({
  comment: z.string().min(1).optional(),
  hold: issueHoldInputSchema.nullable().optional(),
  reopen: z.boolean().optional(),
  hiddenAt: z.string().datetime().nullable().optional(),
});

export type UpdateIssue = z.infer<typeof updateIssueSchema>;
export type IssueExecutionWorkspaceSettings = z.infer<typeof issueExecutionWorkspaceSettingsSchema>;

export const checkoutIssueSchema = z.object({
  agentId: z.string().uuid(),
  expectedStatuses: z.array(z.enum(ISSUE_STATUSES)).nonempty(),
});

export type CheckoutIssue = z.infer<typeof checkoutIssueSchema>;

export const addIssueCommentSchema = z.object({
  body: z.string().min(1),
  reopen: z.boolean().optional(),
  interrupt: z.boolean().optional(),
});

export type AddIssueComment = z.infer<typeof addIssueCommentSchema>;

export const linkIssueApprovalSchema = z.object({
  approvalId: z.string().uuid(),
});

export type LinkIssueApproval = z.infer<typeof linkIssueApprovalSchema>;

export const createIssueAttachmentMetadataSchema = z.object({
  issueCommentId: z.string().uuid().optional().nullable(),
});

export type CreateIssueAttachmentMetadata = z.infer<typeof createIssueAttachmentMetadataSchema>;

export const ISSUE_DOCUMENT_FORMATS = ["markdown"] as const;

export const issueDocumentFormatSchema = z.enum(ISSUE_DOCUMENT_FORMATS);

export const issueDocumentKeySchema = z
  .string()
  .trim()
  .min(1)
  .max(64)
  .regex(/^[a-z0-9][a-z0-9_-]*$/, "Document key must be lowercase letters, numbers, _ or -");

export const upsertIssueDocumentSchema = z.object({
  title: z.string().trim().max(200).nullable().optional(),
  format: issueDocumentFormatSchema,
  body: z.string().max(524288),
  changeSummary: z.string().trim().max(500).nullable().optional(),
  baseRevisionId: z.string().uuid().nullable().optional(),
});

export type IssueDocumentFormat = z.infer<typeof issueDocumentFormatSchema>;
export type UpsertIssueDocument = z.infer<typeof upsertIssueDocumentSchema>;
