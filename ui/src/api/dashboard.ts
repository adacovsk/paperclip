import type { DashboardSummary } from "@paperclipai/shared";
import { api } from "./client";

export const dashboardApi = {
  summary: () => api.get<DashboardSummary>(`/dashboard`),
};
