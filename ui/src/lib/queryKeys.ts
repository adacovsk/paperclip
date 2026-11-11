export const queryKeys = {
  agents: {
    list: ["agents", "list"] as const,
    detail: (id: string) => ["agents", "detail", id] as const,
    runtimeState: (id: string) => ["agents", "runtime-state", id] as const,
    taskSessions: (id: string) => ["agents", "task-sessions", id] as const,
    skills: (id: string) => ["agents", "skills", id] as const,
    instructionsBundle: (id: string) => ["agents", "instructions-bundle", id] as const,
    instructionsFile: (id: string, relativePath: string) =>
      ["agents", "instructions-bundle", id, "file", relativePath] as const,
    keys: (agentId: string) => ["agents", "keys", agentId] as const,
    configRevisions: (agentId: string) => ["agents", "config-revisions", agentId] as const,
    adapterModels: (adapterType: string) =>
      ["agents", "adapter-models", adapterType] as const,
    detectModel: (adapterType: string) =>
      ["agents", "detect-model", adapterType] as const,
  },
  issues: {
    list: ["issues", "list"] as const,
    listByStatus: (status: string) => ["issues", "list", "status", status] as const,
    listOpen: ["issues", "list", "open"] as const,
    listRecent: ["issues", "list", "recent"] as const,
    listClosed: (limit: number) => ["issues", "list", "closed", limit] as const,
    children: (parentId: string) => ["issues", "list", "children", parentId] as const,
    search: (q: string, projectId?: string) =>
      ["issues", "list", "search", q, projectId ?? "__all-projects__"] as const,
    listAssignedToMe: ["issues", "list", "assigned-to-me"] as const,
    listMineByMe: ["issues", "list", "mine-by-me"] as const,
    listTouchedByMe: ["issues", "list", "touched-by-me"] as const,
    listUnreadTouchedByMe: ["issues", "list", "unread-touched-by-me"] as const,
    labels: ["issues", "list", "labels"] as const,
    detail: (id: string) => ["issues", "detail", id] as const,
    comments: (issueId: string) => ["issues", "comments", issueId] as const,
    attachments: (issueId: string) => ["issues", "attachments", issueId] as const,
    documents: (issueId: string) => ["issues", "documents", issueId] as const,
    documentRevisions: (issueId: string, key: string) => ["issues", "document-revisions", issueId, key] as const,
    activity: (issueId: string) => ["issues", "activity", issueId] as const,
    runs: (issueId: string) => ["issues", "runs", issueId] as const,
    approvals: (issueId: string) => ["issues", "approvals", issueId] as const,
    builds: (issueId: string) => ["issues", "builds", issueId] as const,
    liveRuns: (issueId: string) => ["issues", "live-runs", issueId] as const,
    activeRun: (issueId: string) => ["issues", "active-run", issueId] as const,
    workProducts: (issueId: string) => ["issues", "work-products", issueId] as const,
  },
  routines: {
    list: ["routines", "list"] as const,
    detail: (id: string) => ["routines", "detail", id] as const,
    runs: (id: string) => ["routines", "runs", id] as const,
    activity: (id: string) => ["routines", "activity", id] as const,
  },
  executionWorkspaces: {
    list: (filters?: Record<string, string | boolean | undefined>) =>
      ["execution-workspaces", "list", filters ?? {}] as const,
    detail: (id: string) => ["execution-workspaces", "detail", id] as const,
  },
  projects: {
    list: ["projects", "list"] as const,
    detail: (id: string) => ["projects", "detail", id] as const,
  },
  goals: {
    list: ["goals", "list"] as const,
    detail: (id: string) => ["goals", "detail", id] as const,
  },
  budgets: {
    overview: ["budgets", "overview"] as const,
  },
  approvals: {
    all: ["approvals", "list"] as const,
    list: (status?: string) =>
      ["approvals", "list", status] as const,
    detail: (approvalId: string) => ["approvals", "detail", approvalId] as const,
    comments: (approvalId: string) => ["approvals", "comments", approvalId] as const,
    issues: (approvalId: string) => ["approvals", "issues", approvalId] as const,
  },
  access: {
    joinRequests: (status: string = "pending_approval") =>
      ["access", "join-requests", status] as const,
    invite: (token: string) => ["access", "invite", token] as const,
  },
  auth: {
    session: ["auth", "session"] as const,
  },
  instance: {
    profile: ["instance", "profile"] as const,
    generalSettings: ["instance", "general-settings"] as const,
    schedulerHeartbeats: ["instance", "scheduler-heartbeats"] as const,
    experimentalSettings: ["instance", "experimental-settings"] as const,
  },
  health: ["health"] as const,
  secrets: {
    list: ["secrets"] as const,
    providers: ["secret-providers"] as const,
  },
  dashboard: ["dashboard"] as const,
  sidebarBadges: ["sidebar-badges"] as const,
  activity: ["activity"] as const,
  costs: (from?: string, to?: string) =>
    ["costs", from, to] as const,
  usageByProvider: (from?: string, to?: string) =>
    ["usage-by-provider", from, to] as const,
  usageByBiller: (from?: string, to?: string) =>
    ["usage-by-biller", from, to] as const,
  financeSummary: (from?: string, to?: string) =>
    ["finance-summary", from, to] as const,
  financeByBiller: (from?: string, to?: string) =>
    ["finance-by-biller", from, to] as const,
  financeByKind: (from?: string, to?: string) =>
    ["finance-by-kind", from, to] as const,
  financeEvents: (from?: string, to?: string, limit: number = 100) =>
    ["finance-events", from, to, limit] as const,
  usageWindowSpend: ["usage-window-spend"] as const,
  heartbeatsAll: ["heartbeats", "list"] as const,
  heartbeats: (agentId?: string) =>
    ["heartbeats", "list", agentId] as const,
  heartbeatsLatestByAgent: ["heartbeats", "latest-by-agent"] as const,
  runDetail: (runId: string) => ["heartbeat-run", runId] as const,
  runWorkspaceOperations: (runId: string) => ["heartbeat-run", runId, "workspace-operations"] as const,
  liveRuns: ["live-runs"] as const,
  runIssues: (runId: string) => ["run-issues", runId] as const,
  org: ["org"] as const,
  skills: {
    list: ["skills", "list"] as const,
    detail: (skillId: string) => ["skills", "detail", skillId] as const,
    updateStatus: (skillId: string) => ["skills", "detail", skillId, "update-status"] as const,
    file: (skillId: string, relativePath: string) =>
      ["skills", "detail", skillId, "file", relativePath] as const,
    available: ["skills", "available"] as const,
  },
};
