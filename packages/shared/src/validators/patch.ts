import { z } from "zod";

/**
 * `.partial()` for a PATCH body: every field optional, and no field defaults.
 *
 * Zod applies a field's `.default()` even when `.partial()` has made the field
 * optional, so a plain `.partial()` of a create schema fills each omitted field
 * with its create-time default — a PATCH carrying only `status` would also
 * reset `priority` and `requestDepth` on the stored row. Use this for every
 * update schema derived from a schema whose fields carry defaults.
 */
export function patchSchema<Shape extends z.ZodRawShape>(schema: z.ZodObject<Shape>) {
  const withoutDefaults = Object.fromEntries(
    Object.entries(schema.shape).map(([key, field]) => [
      key,
      field instanceof z.ZodDefault ? field.unwrap() : field,
    ]),
  );
  return schema.extend(withoutDefaults).partial() as ReturnType<z.ZodObject<Shape>["partial"]>;
}
