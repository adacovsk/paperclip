import { useCallback, useMemo, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { CLOSED_ISSUE_STATUSES, OPEN_ISSUE_STATUSES, issuesApi } from "../api/issues";
import { queryKeys } from "../lib/queryKeys";

/** How many closed issues one "load more" step adds. */
export const CLOSED_ISSUE_PAGE_SIZE = 500;

const CLOSED_STATUSES = new Set(CLOSED_ISSUE_STATUSES.split(","));

type IssueListScope = {
  projectId?: string;
  participantAgentId?: string;
};

/**
 * The issues behind a list view: every open issue, plus closed issues only when
 * the view's status filter can show them, most recent first and a page at a time.
 *
 * Closed issues are almost all of a long-lived instance's history (tens of
 * thousands of rows, many megabytes), and the list is refetched on every issue
 * event, so loading them unconditionally makes every list page crawl.
 */
export function useBoundedIssueList(scope: IssueListScope) {
  const [statusFilter, setStatusFilter] = useState<string[]>([]);
  const [closedLimit, setClosedLimit] = useState(CLOSED_ISSUE_PAGE_SIZE);
  const wantsClosed = statusFilter.length === 0 || statusFilter.some((status) => CLOSED_STATUSES.has(status));
  const scopeKey = [scope.projectId ?? "__all-projects__", scope.participantAgentId ?? "__all-agents__"] as const;

  const open = useQuery({
    queryKey: [...queryKeys.issues.list, "bounded", ...scopeKey, "open"],
    queryFn: () => issuesApi.list({ ...scope, status: OPEN_ISSUE_STATUSES }),
  });
  const closed = useQuery({
    queryKey: [...queryKeys.issues.list, "bounded", ...scopeKey, "closed", closedLimit],
    queryFn: () => issuesApi.list({ ...scope, status: CLOSED_ISSUE_STATUSES, limit: closedLimit }),
    enabled: wantsClosed,
    placeholderData: keepPreviousData,
  });

  const issues = useMemo(
    () => [...(open.data ?? []), ...(wantsClosed ? closed.data ?? [] : [])],
    [open.data, closed.data, wantsClosed],
  );
  const loadMoreClosed = useCallback(() => setClosedLimit((limit) => limit + CLOSED_ISSUE_PAGE_SIZE), []);

  return {
    issues,
    isLoading: open.isLoading,
    error: (open.error ?? closed.error) as Error | null,
    onStatusFilterChange: setStatusFilter,
    hasMoreClosed: wantsClosed && (closed.data?.length ?? 0) >= closedLimit,
    isLoadingClosed: wantsClosed && closed.isFetching,
    loadMoreClosed,
  };
}
