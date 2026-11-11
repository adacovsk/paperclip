export type SkillSourceType = "local_path" | "github" | "url" | "catalog" | "skills_sh";

export type SkillTrustLevel = "markdown_only" | "assets" | "scripts_executables";

export type SkillCompatibility = "compatible" | "unknown" | "invalid";

export type SkillSourceBadge = "paperclip" | "github" | "local" | "url" | "catalog" | "skills_sh";

export interface SkillFileInventoryEntry {
  path: string;
  kind: "skill" | "markdown" | "reference" | "script" | "asset" | "other";
}

export interface Skill {
  id: string;
  key: string;
  slug: string;
  name: string;
  description: string | null;
  markdown: string;
  sourceType: SkillSourceType;
  sourceLocator: string | null;
  sourceRef: string | null;
  trustLevel: SkillTrustLevel;
  compatibility: SkillCompatibility;
  fileInventory: SkillFileInventoryEntry[];
  metadata: Record<string, unknown> | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface SkillListItem {
  id: string;
  key: string;
  slug: string;
  name: string;
  description: string | null;
  sourceType: SkillSourceType;
  sourceLocator: string | null;
  sourceRef: string | null;
  trustLevel: SkillTrustLevel;
  compatibility: SkillCompatibility;
  fileInventory: SkillFileInventoryEntry[];
  createdAt: Date;
  updatedAt: Date;
  attachedAgentCount: number;
  editable: boolean;
  editableReason: string | null;
  sourceLabel: string | null;
  sourceBadge: SkillSourceBadge;
  sourcePath: string | null;
}

export interface SkillUsageAgent {
  id: string;
  name: string;
  urlKey: string;
  adapterType: string;
  desired: boolean;
  actualState: string | null;
}

export interface SkillDetail extends Skill {
  attachedAgentCount: number;
  usedByAgents: SkillUsageAgent[];
  editable: boolean;
  editableReason: string | null;
  sourceLabel: string | null;
  sourceBadge: SkillSourceBadge;
  sourcePath: string | null;
}

export interface SkillUpdateStatus {
  supported: boolean;
  reason: string | null;
  trackingRef: string | null;
  currentRef: string | null;
  latestRef: string | null;
  hasUpdate: boolean;
}

export interface SkillImportRequest {
  source: string;
}

export interface SkillImportResult {
  imported: Skill[];
  warnings: string[];
}

export interface SkillProjectScanRequest {
  projectIds?: string[];
  workspaceIds?: string[];
}

export interface SkillProjectScanSkipped {
  projectId: string;
  projectName: string;
  workspaceId: string | null;
  workspaceName: string | null;
  path: string | null;
  reason: string;
}

export interface SkillProjectScanConflict {
  slug: string;
  key: string;
  projectId: string;
  projectName: string;
  workspaceId: string;
  workspaceName: string;
  path: string;
  existingSkillId: string;
  existingSkillKey: string;
  existingSourceLocator: string | null;
  reason: string;
}

export interface SkillProjectScanResult {
  scannedProjects: number;
  scannedWorkspaces: number;
  discovered: number;
  imported: Skill[];
  updated: Skill[];
  skipped: SkillProjectScanSkipped[];
  conflicts: SkillProjectScanConflict[];
  warnings: string[];
}

export interface SkillCreateRequest {
  name: string;
  slug?: string | null;
  description?: string | null;
  markdown?: string | null;
}

export interface SkillFileDetail {
  skillId: string;
  path: string;
  kind: SkillFileInventoryEntry["kind"];
  content: string;
  language: string | null;
  markdown: boolean;
  editable: boolean;
}

export interface SkillFileUpdateRequest {
  path: string;
  content: string;
}
