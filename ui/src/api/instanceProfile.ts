import type {
  InstanceProfile,
  UpdateInstanceBranding,
  UpdateInstanceProfile,
} from "@paperclipai/shared";
import { api } from "./client";

export const instanceProfileApi = {
  get: () => api.get<InstanceProfile>("/instance/profile"),
  update: (data: UpdateInstanceProfile) => api.patch<InstanceProfile>("/instance/profile", data),
  updateBranding: (data: UpdateInstanceBranding) =>
    api.patch<InstanceProfile>("/instance/profile/branding", data),
};
