import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { accessApi } from "../api/access";
import { ApiError } from "../api/client";
import { approvalsApi } from "../api/approvals";
import { dashboardApi } from "../api/dashboard";
import { heartbeatsApi } from "../api/heartbeats";
import { issuesApi } from "../api/issues";
import { queryKeys } from "../lib/queryKeys";
import {
  computeInboxBadgeData,
  getRecentTouchedIssues,
  INBOX_ISSUE_STATUSES,
  loadDismissedInboxItems,
  saveDismissedInboxItems,
  loadReadInboxItems,
  saveReadInboxItems,
  READ_ITEMS_KEY,
} from "../lib/inbox";

export function useDismissedInboxItems() {
  const [dismissed, setDismissed] = useState<Set<string>>(loadDismissedInboxItems);

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== "paperclip:inbox:dismissed") return;
      setDismissed(loadDismissedInboxItems());
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const dismiss = (id: string) => {
    setDismissed((prev) => {
      const next = new Set(prev);
      next.add(id);
      saveDismissedInboxItems(next);
      return next;
    });
  };

  const dismissAll = (ids: string[]) => {
    if (ids.length === 0) return;
    setDismissed((prev) => {
      const next = new Set(prev);
      for (const id of ids) next.add(id);
      saveDismissedInboxItems(next);
      return next;
    });
  };

  return { dismissed, dismiss, dismissAll };
}

export function useReadInboxItems() {
  const [readItems, setReadItems] = useState<Set<string>>(loadReadInboxItems);

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== READ_ITEMS_KEY) return;
      setReadItems(loadReadInboxItems());
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const markRead = (id: string) => {
    setReadItems((prev) => {
      const next = new Set(prev);
      next.add(id);
      saveReadInboxItems(next);
      return next;
    });
  };

  return { readItems, markRead };
}

export function useInboxBadge() {
  const { dismissed } = useDismissedInboxItems();

  const { data: approvals = [] } = useQuery({
    queryKey: queryKeys.approvals.list(),
    queryFn: () => approvalsApi.list(),
  });

  const { data: joinRequests = [] } = useQuery({
    queryKey: queryKeys.access.joinRequests(),
    queryFn: async () => {
      try {
        return await accessApi.listJoinRequests("pending_approval");
      } catch (err) {
        if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
          return [];
        }
        throw err;
      }
    },
    retry: false,
  });

  const { data: dashboard } = useQuery({
    queryKey: queryKeys.dashboard,
    queryFn: () => dashboardApi.summary(),
  });

  const { data: mineIssuesRaw = [] } = useQuery({
    queryKey: queryKeys.issues.listMineByMe,
    queryFn: () =>
      issuesApi.list({
        touchedByUserId: "me",
        inboxArchivedByUserId: "me",
        status: INBOX_ISSUE_STATUSES,
      }),
  });

  const mineIssues = useMemo(() => getRecentTouchedIssues(mineIssuesRaw), [mineIssuesRaw]);

  // The badge only needs each agent's most recent run. This hook renders in the
  // Sidebar on every route, so it must not fetch the instance's full run history.
  const { data: heartbeatRuns = [] } = useQuery({
    queryKey: queryKeys.heartbeatsLatestByAgent,
    queryFn: () => heartbeatsApi.latestByAgent(),
  });

  return useMemo(
    () =>
      computeInboxBadgeData({
        approvals,
        joinRequests,
        dashboard,
        heartbeatRuns,
        mineIssues,
        dismissed,
      }),
    [approvals, joinRequests, dashboard, heartbeatRuns, mineIssues, dismissed],
  );
}
