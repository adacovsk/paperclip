import { describe, expect, it } from "vitest";
import { isOnboardingPath, shouldAutoOpenOnboarding } from "./onboarding-route";

describe("isOnboardingPath", () => {
  it("matches the onboarding route", () => {
    expect(isOnboardingPath("/onboarding")).toBe(true);
  });

  it("ignores non-onboarding routes", () => {
    expect(isOnboardingPath("/dashboard")).toBe(false);
    expect(isOnboardingPath("/pap/onboarding")).toBe(false);
  });
});

describe("shouldAutoOpenOnboarding", () => {
  it("opens when the instance has no agents", () => {
    expect(shouldAutoOpenOnboarding({ pathname: "/dashboard", agentCount: 0 })).toBe(true);
  });

  it("stays closed once an agent exists", () => {
    expect(shouldAutoOpenOnboarding({ pathname: "/dashboard", agentCount: 1 })).toBe(false);
  });

  it("leaves the onboarding route to open the wizard itself", () => {
    expect(shouldAutoOpenOnboarding({ pathname: "/onboarding", agentCount: 0 })).toBe(false);
  });
});
