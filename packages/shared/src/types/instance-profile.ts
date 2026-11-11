import type { InstanceStatus, PauseReason } from "../constants.js";

/** The instance's own record: the singleton `instance_settings` row's profile fields. */
export interface InstanceProfile {
  id: string;
  name: string;
  description: string | null;
  status: InstanceStatus;
  pauseReason: PauseReason | null;
  pausedAt: Date | null;
  issuePrefix: string;
  issueCounter: number;
  budgetMonthlyCents: number;
  spentMonthlyCents: number;
  requireOperatorApprovalForNewAgents: boolean;
  brandColor: string | null;
  logoAssetId: string | null;
  logoUrl: string | null;
  createdAt: Date;
  updatedAt: Date;
}
