import { describe, expect, it } from "vitest";
import { stripIssuePrefixFromPath } from "./issue-prefix-redirect";

describe("stripIssuePrefixFromPath", () => {
  it("strips the issue prefix from an old comment link", () => {
    expect(stripIssuePrefixFromPath("/AA/issues/AA-123", "AA")).toBe("/issues/AA-123");
  });

  it("matches the prefix case-insensitively and keeps search and hash", () => {
    expect(stripIssuePrefixFromPath("/aa/issues/AA-1?tab=x#c-1", "AA")).toBe("/issues/AA-1?tab=x#c-1");
  });

  it("sends a bare prefix to the root", () => {
    expect(stripIssuePrefixFromPath("/AA", "AA")).toBe("/");
    expect(stripIssuePrefixFromPath("/AA?x=1", "AA")).toBe("/?x=1");
  });

  it("leaves other paths alone", () => {
    expect(stripIssuePrefixFromPath("/issues/AA-1", "AA")).toBeNull();
    expect(stripIssuePrefixFromPath("/AAB/issues", "AA")).toBeNull();
    expect(stripIssuePrefixFromPath("/AA/issues", null)).toBeNull();
  });

  it("never strips a host route that collides with the prefix", () => {
    expect(stripIssuePrefixFromPath("/org", "ORG")).toBeNull();
  });
});
