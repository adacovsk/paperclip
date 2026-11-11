import { z } from "zod";
import { INSTANCE_STATUSES } from "../constants.js";

const logoAssetIdSchema = z.string().uuid().nullable().optional();
const brandColorSchema = z.string().regex(/^#[0-9a-fA-F]{6}$/).nullable().optional();

export const updateInstanceProfileSchema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().nullable().optional(),
  budgetMonthlyCents: z.number().int().nonnegative().optional(),
  status: z.enum(INSTANCE_STATUSES).optional(),
  spentMonthlyCents: z.number().int().nonnegative().optional(),
  requireOperatorApprovalForNewAgents: z.boolean().optional(),
  brandColor: brandColorSchema,
  logoAssetId: logoAssetIdSchema,
});

export type UpdateInstanceProfile = z.infer<typeof updateInstanceProfileSchema>;

export const updateInstanceBrandingSchema = z
  .object({
    name: z.string().min(1).optional(),
    description: z.string().nullable().optional(),
    brandColor: brandColorSchema,
    logoAssetId: logoAssetIdSchema,
  })
  .strict()
  .refine(
    (value) =>
      value.name !== undefined
      || value.description !== undefined
      || value.brandColor !== undefined
      || value.logoAssetId !== undefined,
    "At least one branding field must be provided",
  );

export type UpdateInstanceBranding = z.infer<typeof updateInstanceBrandingSchema>;
