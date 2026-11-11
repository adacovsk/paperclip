import { randomUUID } from "node:crypto";
import type {
  PaperclipPluginManifestV1,
  PluginCapability,
  PluginEventType,
  InstanceProfile,
  Project,
  Issue,
  IssueComment,
  Agent,
  Goal,
} from "@paperclipai/shared";
import type {
  EventFilter,
  PluginContext,
  PluginEntityRecord,
  PluginEntityUpsert,
  PluginJobContext,
  PluginLauncherRegistration,
  PluginEvent,
  ScopeKey,
  ToolResult,
  ToolRunContext,
  PluginWorkspace,
  AgentSession,
  AgentSessionEvent,
} from "./types.js";

export interface TestHarnessOptions {
  /** Plugin manifest used to seed capability checks and metadata. */
  manifest: PaperclipPluginManifestV1;
  /** Optional capability override. Defaults to `manifest.capabilities`. */
  capabilities?: PluginCapability[];
  /** Initial config returned by `ctx.config.get()`. */
  config?: Record<string, unknown>;
}

export interface TestHarnessLogEntry {
  level: "info" | "warn" | "error" | "debug";
  message: string;
  meta?: Record<string, unknown>;
}

export interface TestHarness {
  /** Fully-typed in-memory plugin context passed to `plugin.setup(ctx)`. */
  ctx: PluginContext;
  /** Seed host entities for `ctx.instance/projects/issues/agents/goals` reads. */
  seed(input: {
    instance?: InstanceProfile;
    projects?: Project[];
    issues?: Issue[];
    issueComments?: IssueComment[];
    agents?: Agent[];
    goals?: Goal[];
  }): void;
  setConfig(config: Record<string, unknown>): void;
  /** Dispatch a host or plugin event to registered handlers. */
  emit(eventType: PluginEventType | `plugin.${string}`, payload: unknown, base?: Partial<PluginEvent>): Promise<void>;
  /** Execute a previously-registered scheduled job handler. */
  runJob(jobKey: string, partial?: Partial<PluginJobContext>): Promise<void>;
  /** Invoke a `ctx.data.register(...)` handler by key. */
  getData<T = unknown>(key: string, params?: Record<string, unknown>): Promise<T>;
  /** Invoke a `ctx.actions.register(...)` handler by key. */
  performAction<T = unknown>(key: string, params?: Record<string, unknown>): Promise<T>;
  /** Execute a registered tool handler via `ctx.tools.execute(...)`. */
  executeTool<T = ToolResult>(name: string, params: unknown, runCtx?: Partial<ToolRunContext>): Promise<T>;
  /** Read raw in-memory state for assertions. */
  getState(input: ScopeKey): unknown;
  /** Simulate a streaming event arriving for an active session. */
  simulateSessionEvent(sessionId: string, event: Omit<AgentSessionEvent, "sessionId">): void;
  logs: TestHarnessLogEntry[];
  activity: Array<{ message: string; entityType?: string; entityId?: string; metadata?: Record<string, unknown> }>;
  metrics: Array<{ name: string; value: number; tags?: Record<string, string> }>;
}

type EventRegistration = {
  name: PluginEventType | `plugin.${string}`;
  filter?: EventFilter;
  fn: (event: PluginEvent) => Promise<void>;
};

function normalizeScope(input: ScopeKey): Required<Pick<ScopeKey, "scopeKind" | "stateKey">> & Pick<ScopeKey, "scopeId" | "namespace"> {
  return {
    scopeKind: input.scopeKind,
    scopeId: input.scopeId,
    namespace: input.namespace ?? "default",
    stateKey: input.stateKey,
  };
}

function stateMapKey(input: ScopeKey): string {
  const normalized = normalizeScope(input);
  return `${normalized.scopeKind}|${normalized.scopeId ?? ""}|${normalized.namespace}|${normalized.stateKey}`;
}

function allowsEvent(filter: EventFilter | undefined, event: PluginEvent): boolean {
  if (!filter) return true;
  if (filter.projectId && filter.projectId !== String((event.payload as Record<string, unknown> | undefined)?.projectId ?? "")) return false;
  if (filter.agentId && filter.agentId !== String((event.payload as Record<string, unknown> | undefined)?.agentId ?? "")) return false;
  return true;
}

function requireCapability(manifest: PaperclipPluginManifestV1, allowed: Set<PluginCapability>, capability: PluginCapability) {
  if (allowed.has(capability)) return;
  throw new Error(`Plugin '${manifest.id}' is missing required capability '${capability}' in test harness`);
}

function defaultInstanceProfile(): InstanceProfile {
  const now = new Date();
  return {
    id: "instance-test",
    name: "Test Instance",
    description: null,
    status: "active",
    pauseReason: null,
    pausedAt: null,
    issuePrefix: "TST",
    issueCounter: 0,
    budgetMonthlyCents: 0,
    spentMonthlyCents: 0,
    requireOperatorApprovalForNewAgents: false,
    brandColor: null,
    logoAssetId: null,
    logoUrl: null,
    createdAt: now,
    updatedAt: now,
  };
}

/**
 * Create an in-memory host harness for plugin worker tests.
 *
 * The harness enforces declared capabilities and simulates host APIs, so tests
 * can validate plugin behavior without spinning up the Paperclip server runtime.
 */
export function createTestHarness(options: TestHarnessOptions): TestHarness {
  const manifest = options.manifest;
  const capabilitySet = new Set(options.capabilities ?? manifest.capabilities);
  let currentConfig = { ...(options.config ?? {}) };

  const logs: TestHarnessLogEntry[] = [];
  const activity: TestHarness["activity"] = [];
  const metrics: TestHarness["metrics"] = [];

  const state = new Map<string, unknown>();
  const entities = new Map<string, PluginEntityRecord>();
  const entityExternalIndex = new Map<string, string>();
  let instanceProfile = defaultInstanceProfile();
  const projects = new Map<string, Project>();
  const issues = new Map<string, Issue>();
  const issueComments = new Map<string, IssueComment[]>();
  const agents = new Map<string, Agent>();
  const goals = new Map<string, Goal>();
  const projectWorkspaces = new Map<string, PluginWorkspace[]>();

  const sessions = new Map<string, AgentSession>();
  const sessionEventCallbacks = new Map<string, (event: AgentSessionEvent) => void>();

  const events: EventRegistration[] = [];
  const jobs = new Map<string, (job: PluginJobContext) => Promise<void>>();
  const launchers = new Map<string, PluginLauncherRegistration>();
  const dataHandlers = new Map<string, (params: Record<string, unknown>) => Promise<unknown>>();
  const actionHandlers = new Map<string, (params: Record<string, unknown>) => Promise<unknown>>();
  const toolHandlers = new Map<string, (params: unknown, runCtx: ToolRunContext) => Promise<ToolResult>>();

  const ctx: PluginContext = {
    manifest,
    config: {
      async get() {
        return { ...currentConfig };
      },
    },
    events: {
      on(name: PluginEventType | `plugin.${string}`, filterOrFn: EventFilter | ((event: PluginEvent) => Promise<void>), maybeFn?: (event: PluginEvent) => Promise<void>): () => void {
        requireCapability(manifest, capabilitySet, "events.subscribe");
        let registration: EventRegistration;
        if (typeof filterOrFn === "function") {
          registration = { name, fn: filterOrFn };
        } else {
          if (!maybeFn) throw new Error("event handler is required");
          registration = { name, filter: filterOrFn, fn: maybeFn };
        }
        events.push(registration);
        return () => {
          const idx = events.indexOf(registration);
          if (idx !== -1) events.splice(idx, 1);
        };
      },
      async emit(name, payload) {
        requireCapability(manifest, capabilitySet, "events.emit");
        await harness.emit(`plugin.${manifest.id}.${name}`, payload);
      },
    },
    jobs: {
      register(key, fn) {
        requireCapability(manifest, capabilitySet, "jobs.schedule");
        jobs.set(key, fn);
      },
    },
    launchers: {
      register(launcher) {
        launchers.set(launcher.id, launcher);
      },
    },
    http: {
      async fetch(url, init) {
        requireCapability(manifest, capabilitySet, "http.outbound");
        return fetch(url, init);
      },
    },
    secrets: {
      async resolve(secretRef) {
        requireCapability(manifest, capabilitySet, "secrets.read-ref");
        return `resolved:${secretRef}`;
      },
    },
    activity: {
      async log(entry) {
        requireCapability(manifest, capabilitySet, "activity.log.write");
        activity.push(entry);
      },
    },
    state: {
      async get(input) {
        requireCapability(manifest, capabilitySet, "plugin.state.read");
        return state.has(stateMapKey(input)) ? state.get(stateMapKey(input)) : null;
      },
      async set(input, value) {
        requireCapability(manifest, capabilitySet, "plugin.state.write");
        state.set(stateMapKey(input), value);
      },
      async delete(input) {
        requireCapability(manifest, capabilitySet, "plugin.state.write");
        state.delete(stateMapKey(input));
      },
    },
    entities: {
      async upsert(input: PluginEntityUpsert) {
        const externalKey = input.externalId
          ? `${input.entityType}|${input.scopeKind}|${input.scopeId ?? ""}|${input.externalId}`
          : null;
        const existingId = externalKey ? entityExternalIndex.get(externalKey) : undefined;
        const existing = existingId ? entities.get(existingId) : undefined;
        const now = new Date().toISOString();
        const previousExternalKey = existing?.externalId
          ? `${existing.entityType}|${existing.scopeKind}|${existing.scopeId ?? ""}|${existing.externalId}`
          : null;
        const record: PluginEntityRecord = existing
          ? {
            ...existing,
            entityType: input.entityType,
            scopeKind: input.scopeKind,
            scopeId: input.scopeId ?? null,
            externalId: input.externalId ?? null,
            title: input.title ?? null,
            status: input.status ?? null,
            data: input.data,
            updatedAt: now,
          }
          : {
            id: randomUUID(),
            entityType: input.entityType,
            scopeKind: input.scopeKind,
            scopeId: input.scopeId ?? null,
            externalId: input.externalId ?? null,
            title: input.title ?? null,
            status: input.status ?? null,
            data: input.data,
            createdAt: now,
            updatedAt: now,
          };
        entities.set(record.id, record);
        if (previousExternalKey && previousExternalKey !== externalKey) {
          entityExternalIndex.delete(previousExternalKey);
        }
        if (externalKey) entityExternalIndex.set(externalKey, record.id);
        return record;
      },
      async list(query) {
        let out = [...entities.values()];
        if (query.entityType) out = out.filter((r) => r.entityType === query.entityType);
        if (query.scopeKind) out = out.filter((r) => r.scopeKind === query.scopeKind);
        if (query.scopeId) out = out.filter((r) => r.scopeId === query.scopeId);
        if (query.externalId) out = out.filter((r) => r.externalId === query.externalId);
        if (query.offset) out = out.slice(query.offset);
        if (query.limit) out = out.slice(0, query.limit);
        return out;
      },
    },
    projects: {
      async list(input) {
        requireCapability(manifest, capabilitySet, "projects.read");
        let out = [...projects.values()];
        if (input?.offset) out = out.slice(input.offset);
        if (input?.limit) out = out.slice(0, input.limit);
        return out;
      },
      async get(projectId) {
        requireCapability(manifest, capabilitySet, "projects.read");
        const project = projects.get(projectId);
        return project ?? null;
      },
      async listWorkspaces(projectId) {
        requireCapability(manifest, capabilitySet, "project.workspaces.read");
        if (!projects.get(projectId)) return [];
        return projectWorkspaces.get(projectId) ?? [];
      },
      async getPrimaryWorkspace(projectId) {
        requireCapability(manifest, capabilitySet, "project.workspaces.read");
        if (!projects.get(projectId)) return null;
        const workspaces = projectWorkspaces.get(projectId) ?? [];
        return workspaces.find((workspace) => workspace.isPrimary) ?? null;
      },
      async getWorkspaceForIssue(issueId) {
        requireCapability(manifest, capabilitySet, "project.workspaces.read");
        const issue = issues.get(issueId);
        if (!issue) return null;
        const projectId = (issue as unknown as Record<string, unknown>)?.projectId as string | undefined;
        if (!projectId) return null;
        if (!projects.get(projectId)) return null;
        const workspaces = projectWorkspaces.get(projectId) ?? [];
        return workspaces.find((workspace) => workspace.isPrimary) ?? null;
      },
    },
    instance: {
      async get() {
        requireCapability(manifest, capabilitySet, "instance.read");
        return instanceProfile;
      },
    },
    issues: {
      async list(input) {
        requireCapability(manifest, capabilitySet, "issues.read");
        let out = [...issues.values()];
        if (input?.projectId) out = out.filter((issue) => issue.projectId === input.projectId);
        if (input?.assigneeAgentId) out = out.filter((issue) => issue.assigneeAgentId === input.assigneeAgentId);
        if (input?.status) out = out.filter((issue) => issue.status === input.status);
        if (input?.offset) out = out.slice(input.offset);
        if (input?.limit) out = out.slice(0, input.limit);
        return out;
      },
      async get(issueId) {
        requireCapability(manifest, capabilitySet, "issues.read");
        const issue = issues.get(issueId);
        return issue ?? null;
      },
      async create(input) {
        requireCapability(manifest, capabilitySet, "issues.create");
        const now = new Date();
        const record: Issue = {
          id: randomUUID(),
          projectId: input.projectId ?? null,
          projectWorkspaceId: null,
          goalId: input.goalId ?? null,
          parentId: input.parentId ?? null,
          title: input.title,
          description: input.description ?? null,
          status: "todo",
          priority: input.priority ?? "medium",
          assigneeAgentId: input.assigneeAgentId ?? null,
          assigneeUserId: null,
          checkoutRunId: null,
          executionRunId: null,
          executionAgentNameKey: null,
          executionLockedAt: null,
          createdByAgentId: null,
          createdByUserId: null,
          issueNumber: null,
          identifier: null,
          requestDepth: 0,
          billingCode: null,
          assigneeAdapterOverrides: null,
          executionWorkspaceId: null,
          executionWorkspacePreference: null,
          executionWorkspaceSettings: null,
          startedAt: null,
          completedAt: null,
          cancelledAt: null,
          hiddenAt: null,
          createdAt: now,
          updatedAt: now,
        };
        issues.set(record.id, record);
        return record;
      },
      async update(issueId, patch) {
        requireCapability(manifest, capabilitySet, "issues.update");
        const record = issues.get(issueId);
        if (!record) throw new Error(`Issue not found: ${issueId}`);
        const updated: Issue = {
          ...record,
          ...patch,
          updatedAt: new Date(),
        };
        issues.set(issueId, updated);
        return updated;
      },
      async listComments(issueId) {
        requireCapability(manifest, capabilitySet, "issue.comments.read");
        if (!issues.get(issueId)) return [];
        return issueComments.get(issueId) ?? [];
      },
      async createComment(issueId, body) {
        requireCapability(manifest, capabilitySet, "issue.comments.create");
        const parentIssue = issues.get(issueId);
        if (!parentIssue) {
          throw new Error(`Issue not found: ${issueId}`);
        }
        const now = new Date();
        const comment: IssueComment = {
          id: randomUUID(),
          issueId,
          authorAgentId: null,
          authorUserId: null,
          body,
          createdAt: now,
          updatedAt: now,
        };
        const current = issueComments.get(issueId) ?? [];
        current.push(comment);
        issueComments.set(issueId, current);
        return comment;
      },
      documents: {
        async list(issueId) {
          requireCapability(manifest, capabilitySet, "issue.documents.read");
          if (!issues.get(issueId)) return [];
          return [];
        },
        async get(issueId, _key) {
          requireCapability(manifest, capabilitySet, "issue.documents.read");
          if (!issues.get(issueId)) return null;
          return null;
        },
        async upsert(input) {
          requireCapability(manifest, capabilitySet, "issue.documents.write");
          const parentIssue = issues.get(input.issueId);
          if (!parentIssue) {
            throw new Error(`Issue not found: ${input.issueId}`);
          }
          throw new Error("documents.upsert is not implemented in test context");
        },
        async delete(issueId, _key) {
          requireCapability(manifest, capabilitySet, "issue.documents.write");
          const parentIssue = issues.get(issueId);
          if (!parentIssue) {
            throw new Error(`Issue not found: ${issueId}`);
          }
        },
      },
    },
    agents: {
      async list(input) {
        requireCapability(manifest, capabilitySet, "agents.read");
        let out = [...agents.values()];
        if (input?.status) out = out.filter((agent) => agent.status === input.status);
        if (input?.offset) out = out.slice(input.offset);
        if (input?.limit) out = out.slice(0, input.limit);
        return out;
      },
      async get(agentId) {
        requireCapability(manifest, capabilitySet, "agents.read");
        const agent = agents.get(agentId);
        return agent ?? null;
      },
      async pause(agentId) {
        requireCapability(manifest, capabilitySet, "agents.pause");
        const agent = agents.get(agentId);
        if (!agent) throw new Error(`Agent not found: ${agentId}`);
        if (agent!.status === "terminated") throw new Error("Cannot pause terminated agent");
        const updated: Agent = { ...agent!, status: "paused", updatedAt: new Date() };
        agents.set(agentId, updated);
        return updated;
      },
      async resume(agentId) {
        requireCapability(manifest, capabilitySet, "agents.resume");
        const agent = agents.get(agentId);
        if (!agent) throw new Error(`Agent not found: ${agentId}`);
        if (agent!.status === "terminated") throw new Error("Cannot resume terminated agent");
        if (agent!.status === "pending_approval") throw new Error("Pending approval agents cannot be resumed");
        const updated: Agent = { ...agent!, status: "idle", updatedAt: new Date() };
        agents.set(agentId, updated);
        return updated;
      },
      async invoke(agentId, opts) {
        requireCapability(manifest, capabilitySet, "agents.invoke");
        const agent = agents.get(agentId);
        if (!agent) throw new Error(`Agent not found: ${agentId}`);
        if (
          agent!.status === "paused" ||
          agent!.status === "terminated" ||
          agent!.status === "pending_approval"
        ) {
          throw new Error(`Agent is not invokable in its current state: ${agent!.status}`);
        }
        return { runId: randomUUID() };
      },
      sessions: {
        async create(agentId, opts) {
          requireCapability(manifest, capabilitySet, "agent.sessions.create");
          const agent = agents.get(agentId);
          if (!agent) throw new Error(`Agent not found: ${agentId}`);
          const session: AgentSession = {
            sessionId: randomUUID(),
            agentId,
            status: "active",
            createdAt: new Date().toISOString(),
          };
          sessions.set(session.sessionId, session);
          return session;
        },
        async list(agentId) {
          requireCapability(manifest, capabilitySet, "agent.sessions.list");
          return [...sessions.values()].filter(
            (s) => s.agentId === agentId && s.status === "active",
          );
        },
        async sendMessage(sessionId, opts) {
          requireCapability(manifest, capabilitySet, "agent.sessions.send");
          const session = sessions.get(sessionId);
          if (!session || session.status !== "active") throw new Error(`Session not found or closed: ${sessionId}`);
          if (opts.onEvent) {
            sessionEventCallbacks.set(sessionId, opts.onEvent);
          }
          return { runId: randomUUID() };
        },
        async close(sessionId) {
          requireCapability(manifest, capabilitySet, "agent.sessions.close");
          const session = sessions.get(sessionId);
          if (!session) throw new Error(`Session not found: ${sessionId}`);
          session.status = "closed";
          sessionEventCallbacks.delete(sessionId);
        },
      },
    },
    goals: {
      async list(input) {
        requireCapability(manifest, capabilitySet, "goals.read");
        let out = [...goals.values()];
        if (input?.level) out = out.filter((goal) => goal.level === input.level);
        if (input?.status) out = out.filter((goal) => goal.status === input.status);
        if (input?.offset) out = out.slice(input.offset);
        if (input?.limit) out = out.slice(0, input.limit);
        return out;
      },
      async get(goalId) {
        requireCapability(manifest, capabilitySet, "goals.read");
        const goal = goals.get(goalId);
        return goal ?? null;
      },
      async create(input) {
        requireCapability(manifest, capabilitySet, "goals.create");
        const now = new Date();
        const record: Goal = {
          id: randomUUID(),
          title: input.title,
          description: input.description ?? null,
          level: input.level ?? "task",
          status: input.status ?? "planned",
          parentId: input.parentId ?? null,
          ownerAgentId: input.ownerAgentId ?? null,
          createdAt: now,
          updatedAt: now,
        };
        goals.set(record.id, record);
        return record;
      },
      async update(goalId, patch) {
        requireCapability(manifest, capabilitySet, "goals.update");
        const record = goals.get(goalId);
        if (!record) throw new Error(`Goal not found: ${goalId}`);
        const updated: Goal = {
          ...record,
          ...patch,
          updatedAt: new Date(),
        };
        goals.set(goalId, updated);
        return updated;
      },
    },
    data: {
      register(key, handler) {
        dataHandlers.set(key, handler);
      },
    },
    actions: {
      register(key, handler) {
        actionHandlers.set(key, handler);
      },
    },
    streams: {
      // No-op in test harness — events are not forwarded
      open(_channel: string) {},
      emit(_channel: string, _event: unknown) {},
      close(_channel: string) {},
    },
    tools: {
      register(name, _decl, fn) {
        requireCapability(manifest, capabilitySet, "agent.tools.register");
        toolHandlers.set(name, fn);
      },
    },
    metrics: {
      async write(name, value, tags) {
        requireCapability(manifest, capabilitySet, "metrics.write");
        metrics.push({ name, value, tags });
      },
    },
    logger: {
      info(message, meta) {
        logs.push({ level: "info", message, meta });
      },
      warn(message, meta) {
        logs.push({ level: "warn", message, meta });
      },
      error(message, meta) {
        logs.push({ level: "error", message, meta });
      },
      debug(message, meta) {
        logs.push({ level: "debug", message, meta });
      },
    },
  };

  const harness: TestHarness = {
    ctx,
    seed(input) {
      if (input.instance) instanceProfile = input.instance;
      for (const row of input.projects ?? []) projects.set(row.id, row);
      for (const row of input.issues ?? []) issues.set(row.id, row);
      for (const row of input.issueComments ?? []) {
        const list = issueComments.get(row.issueId) ?? [];
        list.push(row);
        issueComments.set(row.issueId, list);
      }
      for (const row of input.agents ?? []) agents.set(row.id, row);
      for (const row of input.goals ?? []) goals.set(row.id, row);
    },
    setConfig(config) {
      currentConfig = { ...config };
    },
    async emit(eventType, payload, base) {
      const event: PluginEvent = {
        eventId: base?.eventId ?? randomUUID(),
        eventType,
        occurredAt: base?.occurredAt ?? new Date().toISOString(),
        actorId: base?.actorId,
        actorType: base?.actorType,
        entityId: base?.entityId,
        entityType: base?.entityType,
        payload,
      };

      for (const handler of events) {
        const exactMatch = handler.name === event.eventType;
        const wildcardPluginAll = handler.name === "plugin.*" && String(event.eventType).startsWith("plugin.");
        const wildcardPluginOne = String(handler.name).endsWith(".*")
          && String(event.eventType).startsWith(String(handler.name).slice(0, -1));
        if (!exactMatch && !wildcardPluginAll && !wildcardPluginOne) continue;
        if (!allowsEvent(handler.filter, event)) continue;
        await handler.fn(event);
      }
    },
    async runJob(jobKey, partial = {}) {
      const handler = jobs.get(jobKey);
      if (!handler) throw new Error(`No job handler registered for '${jobKey}'`);
      await handler({
        jobKey,
        runId: partial.runId ?? randomUUID(),
        trigger: partial.trigger ?? "manual",
        scheduledAt: partial.scheduledAt ?? new Date().toISOString(),
      });
    },
    async getData<T = unknown>(key: string, params: Record<string, unknown> = {}) {
      const handler = dataHandlers.get(key);
      if (!handler) throw new Error(`No data handler registered for '${key}'`);
      return await handler(params) as T;
    },
    async performAction<T = unknown>(key: string, params: Record<string, unknown> = {}) {
      const handler = actionHandlers.get(key);
      if (!handler) throw new Error(`No action handler registered for '${key}'`);
      return await handler(params) as T;
    },
    async executeTool<T = ToolResult>(name: string, params: unknown, runCtx: Partial<ToolRunContext> = {}) {
      const handler = toolHandlers.get(name);
      if (!handler) throw new Error(`No tool handler registered for '${name}'`);
      const ctxToPass: ToolRunContext = {
        agentId: runCtx.agentId ?? "agent-test",
        runId: runCtx.runId ?? randomUUID(),
        projectId: runCtx.projectId ?? "project-test",
      };
      return await handler(params, ctxToPass) as T;
    },
    getState(input) {
      return state.get(stateMapKey(input));
    },
    simulateSessionEvent(sessionId, event) {
      const cb = sessionEventCallbacks.get(sessionId);
      if (!cb) throw new Error(`No active session event callback for session: ${sessionId}`);
      cb({ ...event, sessionId });
    },
    logs,
    activity,
    metrics,
  };

  return harness;
}
