import type { Secret, SecretProviderDescriptor, SecretProvider } from "@paperclipai/shared";
import { api } from "./client";

export const secretsApi = {
  list: () => api.get<Secret[]>(`/secrets`),
  providers: () =>
    api.get<SecretProviderDescriptor[]>(`/secret-providers`),
  create: (
    data: {
      name: string;
      value: string;
      provider?: SecretProvider;
      description?: string | null;
      externalRef?: string | null;
    },
  ) => api.post<Secret>(`/secrets`, data),
  rotate: (id: string, data: { value: string; externalRef?: string | null }) =>
    api.post<Secret>(`/secrets/${id}/rotate`, data),
  update: (
    id: string,
    data: { name?: string; description?: string | null; externalRef?: string | null },
  ) => api.patch<Secret>(`/secrets/${id}`, data),
  remove: (id: string) => api.delete<{ ok: true }>(`/secrets/${id}`),
};
