import type {
  Approval,
  DocumentRevision,
  Issue,
  IssueAttachment,
  IssueBuild,
  IssueComment,
  IssueDocument,
  IssueLabel,
  IssueWorkProduct,
  UpsertIssueDocument,
} from "@paperclipai/shared";
import { api } from "./client";

export const OPEN_ISSUE_STATUSES = "backlog,todo,in_progress,in_review,blocked";
export const CLOSED_ISSUE_STATUSES = "done,cancelled";
export const RECENT_ISSUE_WINDOW_DAYS = 14;

export const issuesApi = {
  list: (
    filters?: {
      status?: string;
      projectId?: string;
      parentId?: string;
      assigneeAgentId?: string;
      participantAgentId?: string;
      assigneeUserId?: string;
      touchedByUserId?: string;
      inboxArchivedByUserId?: string;
      unreadForUserId?: string;
      labelId?: string;
      originKind?: string;
      originId?: string;
      includeRoutineExecutions?: boolean;
      q?: string;
      updatedSince?: Date;
      limit?: number;
    },
  ) => {
    const params = new URLSearchParams();
    if (filters?.status) params.set("status", filters.status);
    if (filters?.projectId) params.set("projectId", filters.projectId);
    if (filters?.parentId) params.set("parentId", filters.parentId);
    if (filters?.assigneeAgentId) params.set("assigneeAgentId", filters.assigneeAgentId);
    if (filters?.participantAgentId) params.set("participantAgentId", filters.participantAgentId);
    if (filters?.assigneeUserId) params.set("assigneeUserId", filters.assigneeUserId);
    if (filters?.touchedByUserId) params.set("touchedByUserId", filters.touchedByUserId);
    if (filters?.inboxArchivedByUserId) params.set("inboxArchivedByUserId", filters.inboxArchivedByUserId);
    if (filters?.unreadForUserId) params.set("unreadForUserId", filters.unreadForUserId);
    if (filters?.labelId) params.set("labelId", filters.labelId);
    if (filters?.originKind) params.set("originKind", filters.originKind);
    if (filters?.originId) params.set("originId", filters.originId);
    if (filters?.includeRoutineExecutions) params.set("includeRoutineExecutions", "true");
    if (filters?.q) params.set("q", filters.q);
    if (filters?.updatedSince) params.set("updatedSince", filters.updatedSince.toISOString());
    if (filters?.limit) params.set("limit", String(filters.limit));
    const qs = params.toString();
    return api.get<Issue[]>(`/issues${qs ? `?${qs}` : ""}`);
  },
  /** Issues that are not done or cancelled — a few hundred, where the full list is tens of thousands. */
  listOpen: () => issuesApi.list({ status: OPEN_ISSUE_STATUSES }),
  /** Issues touched in the last RECENT_ISSUE_WINDOW_DAYS days, covering every chart and recent-activity view. */
  listRecent: () =>
    issuesApi.list({ updatedSince: new Date(Date.now() - RECENT_ISSUE_WINDOW_DAYS * 24 * 60 * 60 * 1000) }),
  /** The most recently updated closed issues, `limit` at a time. */
  listClosed: (limit: number) => issuesApi.list({ status: CLOSED_ISSUE_STATUSES, limit }),
  listLabels: () => api.get<IssueLabel[]>(`/labels`),
  createLabel: (data: { name: string; color: string }) =>
    api.post<IssueLabel>(`/labels`, data),
  deleteLabel: (id: string) => api.delete<IssueLabel>(`/labels/${id}`),
  get: (id: string) => api.get<Issue>(`/issues/${id}`),
  markRead: (id: string) => api.post<{ id: string; lastReadAt: Date }>(`/issues/${id}/read`, {}),
  archiveFromInbox: (id: string) =>
    api.post<{ id: string; archivedAt: Date }>(`/issues/${id}/inbox-archive`, {}),
  unarchiveFromInbox: (id: string) =>
    api.delete<{ id: string; archivedAt: Date } | { ok: true }>(`/issues/${id}/inbox-archive`),
  create: (data: Record<string, unknown>) =>
    api.post<Issue>(`/issues`, data),
  update: (id: string, data: Record<string, unknown>) => api.patch<Issue>(`/issues/${id}`, data),
  remove: (id: string) => api.delete<Issue>(`/issues/${id}`),
  checkout: (id: string, agentId: string) =>
    api.post<Issue>(`/issues/${id}/checkout`, {
      agentId,
      expectedStatuses: ["todo", "backlog", "blocked"],
    }),
  release: (id: string) => api.post<Issue>(`/issues/${id}/release`, {}),
  listComments: (id: string) => api.get<IssueComment[]>(`/issues/${id}/comments`),
  addComment: (id: string, body: string, reopen?: boolean, interrupt?: boolean) =>
    api.post<IssueComment>(
      `/issues/${id}/comments`,
      {
        body,
        ...(reopen === undefined ? {} : { reopen }),
        ...(interrupt === undefined ? {} : { interrupt }),
      },
    ),
  listDocuments: (id: string) => api.get<IssueDocument[]>(`/issues/${id}/documents`),
  getDocument: (id: string, key: string) => api.get<IssueDocument>(`/issues/${id}/documents/${encodeURIComponent(key)}`),
  upsertDocument: (id: string, key: string, data: UpsertIssueDocument) =>
    api.put<IssueDocument>(`/issues/${id}/documents/${encodeURIComponent(key)}`, data),
  listDocumentRevisions: (id: string, key: string) =>
    api.get<DocumentRevision[]>(`/issues/${id}/documents/${encodeURIComponent(key)}/revisions`),
  deleteDocument: (id: string, key: string) =>
    api.delete<{ ok: true }>(`/issues/${id}/documents/${encodeURIComponent(key)}`),
  listAttachments: (id: string) => api.get<IssueAttachment[]>(`/issues/${id}/attachments`),
  uploadAttachment: (
    issueId: string,
    file: File,
    issueCommentId?: string | null,
  ) => {
    const form = new FormData();
    form.append("file", file);
    if (issueCommentId) {
      form.append("issueCommentId", issueCommentId);
    }
    return api.postForm<IssueAttachment>(`/issues/${issueId}/attachments`, form);
  },
  deleteAttachment: (id: string) => api.delete<{ ok: true }>(`/attachments/${id}`),
  listBuilds: (id: string) => api.get<IssueBuild[]>(`/issues/${id}/builds`),
  listApprovals: (id: string) => api.get<Approval[]>(`/issues/${id}/approvals`),
  linkApproval: (id: string, approvalId: string) =>
    api.post<Approval[]>(`/issues/${id}/approvals`, { approvalId }),
  unlinkApproval: (id: string, approvalId: string) =>
    api.delete<{ ok: true }>(`/issues/${id}/approvals/${approvalId}`),
  listWorkProducts: (id: string) => api.get<IssueWorkProduct[]>(`/issues/${id}/work-products`),
  createWorkProduct: (id: string, data: Record<string, unknown>) =>
    api.post<IssueWorkProduct>(`/issues/${id}/work-products`, data),
  updateWorkProduct: (id: string, data: Record<string, unknown>) =>
    api.patch<IssueWorkProduct>(`/work-products/${id}`, data),
  deleteWorkProduct: (id: string) => api.delete<IssueWorkProduct>(`/work-products/${id}`),
};
