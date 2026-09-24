import path from "path";
import { defineConfig } from "vitest/config";
import { sharedTestTimeouts } from "../vitest.shared.js";

export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "node",
    ...sharedTestTimeouts,
  },
});
