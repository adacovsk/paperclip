import type {
  BudgetIncident,
  BudgetIncidentResolutionInput,
  BudgetOverview,
  BudgetPolicySummary,
  BudgetPolicyUpsertInput,
} from "@paperclipai/shared";
import { api } from "./client";

export const budgetsApi = {
  overview: () =>
    api.get<BudgetOverview>(`/budgets/overview`),
  upsertPolicy: (data: BudgetPolicyUpsertInput) =>
    api.post<BudgetPolicySummary>(`/budgets/policies`, data),
  resolveIncident: (incidentId: string, data: BudgetIncidentResolutionInput) =>
    api.post<BudgetIncident>(
      `/budget-incidents/${encodeURIComponent(incidentId)}/resolve`,
      data,
    ),
};
