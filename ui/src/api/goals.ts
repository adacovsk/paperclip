import type { Goal } from "@paperclipai/shared";
import { api } from "./client";

export const goalsApi = {
  list: () => api.get<Goal[]>(`/goals`),
  get: (id: string) => api.get<Goal>(`/goals/${id}`),
  create: (data: Record<string, unknown>) =>
    api.post<Goal>(`/goals`, data),
  update: (id: string, data: Record<string, unknown>) => api.patch<Goal>(`/goals/${id}`, data),
  remove: (id: string) => api.delete<Goal>(`/goals/${id}`),
};
