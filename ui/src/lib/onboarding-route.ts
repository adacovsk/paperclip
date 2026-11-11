export function isOnboardingPath(pathname: string): boolean {
  const segments = pathname.split("/").filter(Boolean);
  return segments.length === 1 && segments[0]?.toLowerCase() === "onboarding";
}

/**
 * Onboarding opens on its own when the instance has no agents yet, except on
 * the onboarding route itself, which opens it explicitly.
 */
export function shouldAutoOpenOnboarding(params: {
  pathname: string;
  agentCount: number;
}): boolean {
  return params.agentCount === 0 && !isOnboardingPath(params.pathname);
}
