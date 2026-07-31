/**
 * Timeouts shared by every vitest project.
 *
 * Vitest does not cascade `test` options from the root config into `projects`,
 * so each project config has to spread these in itself.
 *
 * Vitest's 5s default is not survivable here: suites stand up embedded Postgres
 * instances and transform large route modules through tsx, and a full parallel
 * run makes both several times slower than the same test in isolation. Under
 * the default the suite failed a different handful of tests every run purely
 * from load, which reads as a broken tree rather than a slow one.
 */
export const sharedTestTimeouts = {
  testTimeout: 60_000,
  hookTimeout: 120_000,
} as const;
