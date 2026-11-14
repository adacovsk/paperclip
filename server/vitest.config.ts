import os from "node:os";
import path from "node:path";
import { defineConfig } from "vitest/config";
import { sharedTestTimeouts } from "../vitest.shared.js";

export default defineConfig({
  test: {
    environment: "node",
    // The logger otherwise resolves to the live instance's logs/server.log, and
    // every warning a test provokes lands in the operator's server log as if the
    // running server had logged it.
    env: { PAPERCLIP_LOG_DIR: path.join(os.tmpdir(), "paperclip-test-logs") },
    ...sharedTestTimeouts,
  },
});
