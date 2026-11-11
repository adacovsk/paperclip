import type {
  Skill,
  SkillCreateRequest,
  SkillDetail,
  SkillFileDetail,
  SkillImportResult,
  SkillListItem,
  SkillProjectScanRequest,
  SkillProjectScanResult,
  SkillUpdateStatus,
} from "@paperclipai/shared";
import { api } from "./client";

export const skillsApi = {
  list: () =>
    api.get<SkillListItem[]>(`/skills`),
  detail: (skillId: string) =>
    api.get<SkillDetail>(
      `/skills/${encodeURIComponent(skillId)}`,
    ),
  updateStatus: (skillId: string) =>
    api.get<SkillUpdateStatus>(
      `/skills/${encodeURIComponent(skillId)}/update-status`,
    ),
  file: (skillId: string, relativePath: string) =>
    api.get<SkillFileDetail>(
      `/skills/${encodeURIComponent(skillId)}/files?path=${encodeURIComponent(relativePath)}`,
    ),
  updateFile: (skillId: string, path: string, content: string) =>
    api.patch<SkillFileDetail>(
      `/skills/${encodeURIComponent(skillId)}/files`,
      { path, content },
    ),
  create: (payload: SkillCreateRequest) =>
    api.post<Skill>(
      `/skills`,
      payload,
    ),
  importFromSource: (source: string) =>
    api.post<SkillImportResult>(
      `/skills/import`,
      { source },
    ),
  scanProjects: (payload: SkillProjectScanRequest = {}) =>
    api.post<SkillProjectScanResult>(
      `/skills/scan-projects`,
      payload,
    ),
  installUpdate: (skillId: string) =>
    api.post<Skill>(
      `/skills/${encodeURIComponent(skillId)}/install-update`,
      {},
    ),
};
