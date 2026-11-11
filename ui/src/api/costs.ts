import type {
  CostSummary,
  CostByAgent,
  CostByProviderModel,
  CostByBiller,
  CostByAgentModel,
  CostByProject,
  CostWindowSpendRow,
  FinanceSummary,
  FinanceByBiller,
  FinanceByKind,
  FinanceEvent,
} from "@paperclipai/shared";
import { api } from "./client";

function dateParams(from?: string, to?: string): string {
  const params = new URLSearchParams();
  if (from) params.set("from", from);
  if (to) params.set("to", to);
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

export const costsApi = {
  summary: (from?: string, to?: string) =>
    api.get<CostSummary>(`/costs/summary${dateParams(from, to)}`),
  byAgent: (from?: string, to?: string) =>
    api.get<CostByAgent[]>(`/costs/by-agent${dateParams(from, to)}`),
  byAgentModel: (from?: string, to?: string) =>
    api.get<CostByAgentModel[]>(`/costs/by-agent-model${dateParams(from, to)}`),
  byProject: (from?: string, to?: string) =>
    api.get<CostByProject[]>(`/costs/by-project${dateParams(from, to)}`),
  byProvider: (from?: string, to?: string) =>
    api.get<CostByProviderModel[]>(`/costs/by-provider${dateParams(from, to)}`),
  byBiller: (from?: string, to?: string) =>
    api.get<CostByBiller[]>(`/costs/by-biller${dateParams(from, to)}`),
  financeSummary: (from?: string, to?: string) =>
    api.get<FinanceSummary>(`/costs/finance-summary${dateParams(from, to)}`),
  financeByBiller: (from?: string, to?: string) =>
    api.get<FinanceByBiller[]>(`/costs/finance-by-biller${dateParams(from, to)}`),
  financeByKind: (from?: string, to?: string) =>
    api.get<FinanceByKind[]>(`/costs/finance-by-kind${dateParams(from, to)}`),
  financeEvents: (from?: string, to?: string, limit: number = 100) =>
    api.get<FinanceEvent[]>(`/costs/finance-events${dateParamsWithLimit(from, to, limit)}`),
  windowSpend: () =>
    api.get<CostWindowSpendRow[]>(`/costs/window-spend`),
};

function dateParamsWithLimit(from?: string, to?: string, limit?: number): string {
  const params = new URLSearchParams();
  if (from) params.set("from", from);
  if (to) params.set("to", to);
  if (limit) params.set("limit", String(limit));
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}
