import { createServer, type Server } from "node:net";
import { describe, expect, it } from "vitest";
import { findAvailablePort, isPortAvailable } from "./ports.js";

function listen(port: number, host: string): Promise<Server> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(port, host, () => resolve(server));
  });
}

describe("findAvailablePort", () => {
  it("skips a port held on loopback", async () => {
    const held = await listen(0, "127.0.0.1");
    const port = (held.address() as { port: number }).port;
    try {
      expect(await isPortAvailable(port)).toBe(false);
      expect(await findAvailablePort(port)).toBeGreaterThan(port);
    } finally {
      held.close();
    }
  });

  it("skips reserved ports", async () => {
    const start = await findAvailablePort(42000);
    const next = await findAvailablePort(start, new Set([start]));
    expect(next).toBeGreaterThan(start);
  });
});
