import type { Project, ProjectWorkspace } from "@paperclipai/shared";
import { api } from "./client";

function projectPath(id: string, suffix = "") {
  return `/projects/${encodeURIComponent(id)}${suffix}`;
}

export const projectsApi = {
  list: () => api.get<Project[]>(`/projects`),
  get: (id: string) => api.get<Project>(projectPath(id)),
  create: (data: Record<string, unknown>) =>
    api.post<Project>(`/projects`, data),
  update: (id: string, data: Record<string, unknown>) =>
    api.patch<Project>(projectPath(id), data),
  listWorkspaces: (projectId: string) =>
    api.get<ProjectWorkspace[]>(projectPath(projectId, "/workspaces")),
  createWorkspace: (projectId: string, data: Record<string, unknown>) =>
    api.post<ProjectWorkspace>(projectPath(projectId, "/workspaces"), data),
  updateWorkspace: (projectId: string, workspaceId: string, data: Record<string, unknown>) =>
    api.patch<ProjectWorkspace>(
      projectPath(projectId, `/workspaces/${encodeURIComponent(workspaceId)}`),
      data,
    ),
  removeWorkspace: (projectId: string, workspaceId: string) =>
    api.delete<ProjectWorkspace>(projectPath(projectId, `/workspaces/${encodeURIComponent(workspaceId)}`)),
  remove: (id: string) => api.delete<Project>(projectPath(id)),
};
