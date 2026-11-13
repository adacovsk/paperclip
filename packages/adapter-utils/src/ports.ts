import { createServer } from "node:net";

// Free-port search shared by the server and the CLI. It replaces the
// `detect-port` dependency and the CLI's private copy of the same loop.

// A port is free only if it binds on both the wildcard address and loopback.
// Checking loopback alone (the CLI's old check) passes a port that another
// process holds on a specific interface, and the server, which may listen on
// 0.0.0.0, then fails to bind it.
function bindsOn(port: number, host?: string): Promise<boolean> {
  return new Promise((resolve) => {
    const server = createServer();
    server.unref();
    server.once("error", () => resolve(false));
    server.listen({ port, host, exclusive: true }, () => {
      server.close(() => resolve(true));
    });
  });
}

export async function isPortAvailable(port: number): Promise<boolean> {
  return (await bindsOn(port)) && (await bindsOn(port, "127.0.0.1"));
}

/** The first free port at or above `preferredPort`, skipping `reserved`. */
export async function findAvailablePort(
  preferredPort: number,
  reserved: ReadonlySet<number> = new Set(),
): Promise<number> {
  let port = Math.max(1, Math.trunc(preferredPort));
  while (port <= 65535) {
    if (!reserved.has(port) && (await isPortAvailable(port))) return port;
    port += 1;
  }
  throw new Error(`No free port at or above ${preferredPort}`);
}
