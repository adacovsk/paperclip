import type { IssueHold } from "../issue-hold.js";
import type { IssueOriginKind, IssuePriority, IssueStatus } from "../constants.js";
import type { Goal } from "./goal.js";
import type { Project, ProjectWorkspace } from "./project.js";
import type { ExecutionWorkspace, IssueExecutionWorkspaceSettings } from "./workspace-runtime.js";
import type { IssueWorkProduct } from "./work-product.js";
import type { IssueGithubLink } from "../issue-github-link.js";

export interface IssueAncestorProject {
  id: string;
  name: string;
  description: string | null;
  status: string;
  goalId: string | null;
  workspaces: ProjectWorkspace[];
  primaryWorkspace: ProjectWorkspace | null;
}

export interface IssueAncestorGoal {
  id: string;
  title: string;
  description: string | null;
  level: string;
  status: string;
}

export interface IssueAncestor {
  id: string;
  identifier: string | null;
  title: string;
  description: string | null;
  status: string;
  priority: string;
  assigneeAgentId: string | null;
  assigneeUserId: string | null;
  projectId: string | null;
  goalId: string | null;
  project: IssueAncestorProject | null;
  goal: IssueAncestorGoal | null;
}

export interface IssueLabel {
  id: string;
  name: string;
  color: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface IssueAssigneeAdapterOverrides {
  adapterConfig?: Record<string, unknown>;
  useProjectWorkspace?: boolean;
}

export type DocumentFormat = "markdown";

export interface IssueDocumentSummary {
  id: string;
  issueId: string;
  key: string;
  title: string | null;
  format: DocumentFormat;
  latestRevisionId: string | null;
  latestRevisionNumber: number;
  createdByAgentId: string | null;
  createdByUserId: string | null;
  updatedByAgentId: string | null;
  updatedByUserId: string | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface IssueDocument extends IssueDocumentSummary {
  body: string;
}

export interface DocumentRevision {
  id: string;
  documentId: string;
  issueId: string;
  key: string;
  revisionNumber: number;
  body: string;
  changeSummary: string | null;
  createdByAgentId: string | null;
  createdByUserId: string | null;
  createdAt: Date;
}

export interface LegacyPlanDocument {
  key: "plan";
  body: string;
  source: "issue_description";
}

export interface Issue {
  id: string;
  projectId: string | null;
  projectWorkspaceId: string | null;
  goalId: string | null;
  parentId: string | null;
  ancestors?: IssueAncestor[];
  title: string;
  description: string | null;
  status: IssueStatus;
  priority: IssuePriority;
  assigneeAgentId: string | null;
  assigneeUserId: string | null;
  checkoutRunId: string | null;
  executionRunId: string | null;
  executionAgentNameKey: string | null;
  executionLockedAt: Date | null;
  createdByAgentId: string | null;
  createdByUserId: string | null;
  issueNumber: number | null;
  identifier: string | null;
  originKind?: IssueOriginKind;
  originId?: string | null;
  originRunId?: string | null;
  requestDepth: number;
  billingCode: string | null;
  assigneeAdapterOverrides: IssueAssigneeAdapterOverrides | null;
  executionWorkspaceId: string | null;
  executionWorkspacePreference: string | null;
  executionWorkspaceSettings: IssueExecutionWorkspaceSettings | null;
  startedAt: Date | null;
  completedAt: Date | null;
  cancelledAt: Date | null;
  hiddenAt: Date | null;
  /** Why the task is parked and what releases it; null when it is not held. */
  hold: IssueHold | null;
  /** The hold most recently cleared, which is what marks a later one `reheld`. */
  releasedHold: IssueHold | null;
  labelIds?: string[];
  labels?: IssueLabel[];
  planDocument?: IssueDocument | null;
  documentSummaries?: IssueDocumentSummary[];
  legacyPlanDocument?: LegacyPlanDocument | null;
  project?: Project | null;
  goal?: Goal | null;
  currentExecutionWorkspace?: ExecutionWorkspace | null;
  workProducts?: IssueWorkProduct[];
  githubLinks?: IssueGithubLink[];
  mentionedProjects?: Project[];
  myLastTouchAt?: Date | null;
  lastExternalCommentAt?: Date | null;
  isUnreadForMe?: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export interface IssueComment {
  id: string;
  issueId: string;
  authorAgentId: string | null;
  authorUserId: string | null;
  body: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface IssueAttachment {
  id: string;
  issueId: string;
  issueCommentId: string | null;
  assetId: string;
  provider: string;
  objectKey: string;
  contentType: string;
  byteSize: number;
  sha256: string;
  originalFilename: string | null;
  createdByAgentId: string | null;
  createdByUserId: string | null;
  createdAt: Date;
  updatedAt: Date;
  contentPath: string;
}
