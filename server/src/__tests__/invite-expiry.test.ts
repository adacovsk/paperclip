import { describe, expect, it } from "vitest";
import { inviteExpiresAt } from "../routes/access.js";

describe("inviteExpiresAt", () => {
  it("sets invite expiration to 10 minutes after invite creation time", () => {
    const createdAtMs = Date.parse("2026-03-06T00:00:00.000Z");
    const expiresAt = inviteExpiresAt(createdAtMs);
    expect(expiresAt.toISOString()).toBe("2026-03-06T00:10:00.000Z");
  });
});
