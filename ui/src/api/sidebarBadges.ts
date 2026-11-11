import type { SidebarBadges } from "@paperclipai/shared";
import { api } from "./client";

export const sidebarBadgesApi = {
  get: () => api.get<SidebarBadges>(`/sidebar-badges`),
};
