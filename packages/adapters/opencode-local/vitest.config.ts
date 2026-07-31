import { defineConfig } from "vitest/config";
import { sharedTestTimeouts } from "../../../vitest.shared.js";

export default defineConfig({
  test: {
    environment: "node",
    ...sharedTestTimeouts,
  },
});
