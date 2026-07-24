import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Timeouts are not inherited by projects — see vitest.shared.ts, which each
    // project config spreads in.
    projects: ["packages/db", "packages/adapters/opencode-local", "server", "ui", "cli"],
  },
});
