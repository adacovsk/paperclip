import { spawn } from "node:child_process";

// Open a URL in the desktop's default browser. Replaces the `open` dependency,
// which had one caller (PAPERCLIP_OPEN_ON_LISTEN). The opener is detached and
// unreferenced, so it never holds the process open; a missing opener (a
// headless box with no xdg-open) rejects instead of throwing.
export function openUrl(url: string): Promise<void> {
  const [command, args] =
    process.platform === "darwin"
      ? ["open", [url]]
      : process.platform === "win32"
        ? ["cmd", ["/c", "start", '""', url.replace(/&/g, "^&")]]
        : ["xdg-open", [url]];
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: "ignore" });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });
}
