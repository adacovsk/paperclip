import { describe, expect, it } from "vitest";
import { listAdapterModels } from "../adapters/index.js";

describe("adapter model listing", () => {
  it("returns an empty list for unknown adapters", async () => {
    const models = await listAdapterModels("unknown_adapter");
    expect(models).toEqual([]);
  });
});
