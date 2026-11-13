import type { Config } from "../config.js";
import type { StorageProvider } from "./types.js";
import { createLocalDiskStorageProvider } from "./local-disk-provider.js";

export function createStorageProviderFromConfig(config: Config): StorageProvider {
  return createLocalDiskStorageProvider(config.storageLocalDiskBaseDir);
}
