import fs from "node:fs";
import type { PaperclipConfig } from "../config/schema.js";
import type { CheckResult } from "./index.js";
import { resolveRuntimeLikePath } from "./path-resolver.js";

export function storageCheck(config: PaperclipConfig, configPath?: string): CheckResult {
  const baseDir = resolveRuntimeLikePath(config.storage.localDisk.baseDir, configPath);
  if (!fs.existsSync(baseDir)) {
    fs.mkdirSync(baseDir, { recursive: true });
  }

  try {
    fs.accessSync(baseDir, fs.constants.W_OK);
    return {
      name: "Storage",
      status: "pass",
      message: `Local disk storage is writable: ${baseDir}`,
    };
  } catch {
    return {
      name: "Storage",
      status: "fail",
      message: `Local storage directory is not writable: ${baseDir}`,
      canRepair: false,
      repairHint: "Check file permissions for storage.localDisk.baseDir",
    };
  }
}
