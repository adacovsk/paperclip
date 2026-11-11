import { useQuery } from "@tanstack/react-query";
import type { InstanceProfile } from "@paperclipai/shared";
import { instanceProfileApi } from "../api/instanceProfile";
import { ApiError } from "../api/client";
import { queryKeys } from "../lib/queryKeys";

/**
 * The instance's profile (name, issue prefix, branding, budget). Resolves to
 * `null` while signed out, so callers rendered before authentication do not error.
 */
export function useInstanceProfile() {
  const query = useQuery({
    queryKey: queryKeys.instance.profile,
    queryFn: async (): Promise<InstanceProfile | null> => {
      try {
        return await instanceProfileApi.get();
      } catch (err) {
        if (err instanceof ApiError && err.status === 401) return null;
        throw err;
      }
    },
    retry: false,
  });

  return {
    profile: query.data ?? null,
    loading: query.isLoading,
    error: query.error as Error | null,
  };
}
