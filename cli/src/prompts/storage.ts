import * as p from "@clack/prompts";
import { promptText } from "./text.js";
import type { StorageConfig } from "../config/schema.js";
import { resolveDefaultStorageDir, resolvePaperclipInstanceId } from "../config/home.js";

function defaultStorageBaseDir(): string {
  return resolveDefaultStorageDir(resolvePaperclipInstanceId());
}

export function defaultStorageConfig(): StorageConfig {
  return {
    provider: "local_disk",
    localDisk: {
      baseDir: defaultStorageBaseDir(),
    },
  };
}

export async function promptStorage(current?: StorageConfig): Promise<StorageConfig> {
  const base = current ?? defaultStorageConfig();

  const baseDir = await promptText({
    message: "Local storage base directory",
    defaultValue: base.localDisk.baseDir || defaultStorageBaseDir(),
    placeholder: defaultStorageBaseDir(),
    validate: (value) => {
      if (!value || value.trim().length === 0) return "Storage base directory is required";
    },
  });

  if (p.isCancel(baseDir)) {
    p.cancel("Setup cancelled.");
    process.exit(0);
  }

  return {
    provider: "local_disk",
    localDisk: {
      baseDir: baseDir.trim(),
    },
  };
}
