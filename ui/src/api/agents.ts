import type {
  Agent,
  AgentDetail,
  AgentInstructionsBundle,
  AgentInstructionsFileDetail,
  AgentSkillSnapshot,
  AdapterEnvironmentTestResult,
  AgentKeyCreated,
  AgentRuntimeState,
  AgentTaskSession,
  HeartbeatRun,
  Approval,
  AgentConfigRevision,
} from "@paperclipai/shared";
import { isUuidLike, normalizeAgentUrlKey } from "@paperclipai/shared";
import { ApiError, api } from "./client";

export interface AgentKey {
  id: string;
  name: string;
  createdAt: Date;
  revokedAt: Date | null;
}

export interface AdapterModel {
  id: string;
  label: string;
}

export interface DetectedAdapterModel {
  model: string;
  provider: string;
  source: string;
}

export interface ClaudeLoginResult {
  exitCode: number | null;
  signal: string | null;
  timedOut: boolean;
  loginUrl: string | null;
  stdout: string;
  stderr: string;
}

export interface OrgNode {
  id: string;
  name: string;
  role: string;
  status: string;
  reports: OrgNode[];
}

export interface AgentHireResponse {
  agent: Agent;
  approval: Approval | null;
}

export interface AgentPermissionUpdate {
  canCreateAgents: boolean;
  canAssignTasks: boolean;
  canReadConfigurations?: boolean;
}

function agentPath(id: string, suffix = "") {
  return `/agents/${encodeURIComponent(id)}${suffix}`;
}

export const agentsApi = {
  list: () => api.get<Agent[]>(`/agents`),
  org: () => api.get<OrgNode[]>(`/org`),
  listConfigurations: () =>
    api.get<Record<string, unknown>[]>(`/agent-configurations`),
  get: async (id: string) => {
    try {
      return await api.get<AgentDetail>(agentPath(id));
    } catch (error) {
      // A shortname shared by a terminated agent is ambiguous to the backend;
      // resolve it against the agent list while ignoring terminated agents.
      if (
        !(error instanceof ApiError) ||
        error.status !== 409 ||
        isUuidLike(id)
      ) {
        throw error;
      }

      const urlKey = normalizeAgentUrlKey(id);
      if (!urlKey) throw error;

      const agents = await api.get<Agent[]>(`/agents`);
      const matches = agents.filter(
        (agent) => agent.status !== "terminated" && normalizeAgentUrlKey(agent.urlKey) === urlKey,
      );
      if (matches.length !== 1) throw error;
      return api.get<AgentDetail>(agentPath(matches[0]!.id));
    }
  },
  getConfiguration: (id: string) =>
    api.get<Record<string, unknown>>(agentPath(id, "/configuration")),
  listConfigRevisions: (id: string) =>
    api.get<AgentConfigRevision[]>(agentPath(id, "/config-revisions")),
  getConfigRevision: (id: string, revisionId: string) =>
    api.get<AgentConfigRevision>(agentPath(id, `/config-revisions/${revisionId}`)),
  rollbackConfigRevision: (id: string, revisionId: string) =>
    api.post<Agent>(agentPath(id, `/config-revisions/${revisionId}/rollback`), {}),
  create: (data: Record<string, unknown>) =>
    api.post<Agent>(`/agents`, data),
  hire: (data: Record<string, unknown>) =>
    api.post<AgentHireResponse>(`/agent-hires`, data),
  update: (id: string, data: Record<string, unknown>) =>
    api.patch<Agent>(agentPath(id), data),
  updatePermissions: (id: string, data: AgentPermissionUpdate) =>
    api.patch<AgentDetail>(agentPath(id, "/permissions"), data),
  instructionsBundle: (id: string) =>
    api.get<AgentInstructionsBundle>(agentPath(id, "/instructions-bundle")),
  updateInstructionsBundle: (
    id: string,
    data: {
      mode?: "managed" | "external";
      rootPath?: string | null;
      entryFile?: string;
      clearLegacyPromptTemplate?: boolean;
    },
  ) => api.patch<AgentInstructionsBundle>(agentPath(id, "/instructions-bundle"), data),
  instructionsFile: (id: string, relativePath: string) =>
    api.get<AgentInstructionsFileDetail>(
      agentPath(id, `/instructions-bundle/file?path=${encodeURIComponent(relativePath)}`),
    ),
  saveInstructionsFile: (
    id: string,
    data: { path: string; content: string; clearLegacyPromptTemplate?: boolean },
  ) => api.put<AgentInstructionsFileDetail>(agentPath(id, "/instructions-bundle/file"), data),
  deleteInstructionsFile: (id: string, relativePath: string) =>
    api.delete<AgentInstructionsBundle>(
      agentPath(id, `/instructions-bundle/file?path=${encodeURIComponent(relativePath)}`),
    ),
  pause: (id: string) => api.post<Agent>(agentPath(id, "/pause"), {}),
  resume: (id: string) => api.post<Agent>(agentPath(id, "/resume"), {}),
  terminate: (id: string) => api.post<Agent>(agentPath(id, "/terminate"), {}),
  remove: (id: string) => api.delete<{ ok: true }>(agentPath(id)),
  listKeys: (id: string) => api.get<AgentKey[]>(agentPath(id, "/keys")),
  skills: (id: string) =>
    api.get<AgentSkillSnapshot>(agentPath(id, "/skills")),
  syncSkills: (id: string, desiredSkills: string[]) =>
    api.post<AgentSkillSnapshot>(agentPath(id, "/skills/sync"), { desiredSkills }),
  createKey: (id: string, name: string) =>
    api.post<AgentKeyCreated>(agentPath(id, "/keys"), { name }),
  revokeKey: (agentId: string, keyId: string) =>
    api.delete<{ ok: true }>(agentPath(agentId, `/keys/${encodeURIComponent(keyId)}`)),
  runtimeState: (id: string) =>
    api.get<AgentRuntimeState>(agentPath(id, "/runtime-state")),
  taskSessions: (id: string) =>
    api.get<AgentTaskSession[]>(agentPath(id, "/task-sessions")),
  resetSession: (id: string, taskKey?: string | null) =>
    api.post<void>(agentPath(id, "/runtime-state/reset-session"), { taskKey: taskKey ?? null }),
  adapterModels: (type: string) =>
    api.get<AdapterModel[]>(
      `/adapters/${encodeURIComponent(type)}/models`,
    ),
  detectModel: (type: string) =>
    api.get<DetectedAdapterModel | null>(
      `/adapters/${encodeURIComponent(type)}/detect-model`,
    ),
  testEnvironment: (
    type: string,
    data: { adapterConfig: Record<string, unknown> },
  ) =>
    api.post<AdapterEnvironmentTestResult>(
      `/adapters/${type}/test-environment`,
      data,
    ),
  invoke: (id: string) => api.post<HeartbeatRun>(agentPath(id, "/heartbeat/invoke"), {}),
  wakeup: (
    id: string,
    data: {
      source?: "timer" | "assignment" | "on_demand" | "automation";
      triggerDetail?: "manual" | "ping" | "callback" | "system";
      reason?: string | null;
      payload?: Record<string, unknown> | null;
      idempotencyKey?: string | null;
    },
  ) => api.post<HeartbeatRun | { status: "skipped" }>(agentPath(id, "/wakeup"), data),
  loginWithClaude: (id: string) =>
    api.post<ClaudeLoginResult>(agentPath(id, "/claude-login"), {}),
  availableSkills: () =>
    api.get<{ skills: AvailableSkill[] }>("/skills/available"),
};

export interface AvailableSkill {
  name: string;
  description: string;
  isPaperclipManaged: boolean;
}
