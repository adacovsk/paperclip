/**
 * A provider usage limit is a wall-clock wait with a known end, not a failure to
 * retry.
 *
 * Nothing used to treat it that way. The adapter reported it as an ordinary
 * non-zero exit, so a scheduled agent re-fired into the same hard error every
 * interval: one fleet burned 46 runs across ~17h, 35 of them a single agent's
 * half-hourly cron, each a fresh process launch against a limit that was known to
 * be exhausted and known to reset at a fixed wall-clock time. Nothing surfaced it
 * either — no task changed status, so every status-based sweep read the board as
 * merely quiet.
 *
 * The reset instant is parsed by the adapter that owns the message format and
 * carried here in `errorMeta`. This module owns only what the server does with
 * it: where it is stored, and when it has passed.
 */

export const USAGE_LIMIT_ERROR_CODE = "claude_usage_limit";

/**
 * How long to hold off when the limit message carried no reset time.
 *
 * Deliberately short. The cost this prevents is a re-fire every scheduler tick;
 * holding off for half an hour removes essentially all of it, while a long guess
 * would idle a fleet whose limit had already lifted. Each fresh limit hit
 * re-arms the window, so a wrong guess costs one run per window, not a stall.
 */
export const USAGE_LIMIT_FALLBACK_BACKOFF_MS = 30 * 60 * 1000;

export type UsageLimitState = {
  resetAt: string;
  scope: string | null;
  resetText: string | null;
  observedAt: string;
  runId: string | null;
};

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function asTrimmedString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

/**
 * Read a limit out of an adapter result, or null when the run failed for any
 * other reason.
 *
 * Gated on the error code rather than on `errorMeta` alone, so an adapter that
 * reports limit metadata without classifying the failure cannot suppress wakes.
 */
export function usageLimitFromResult(
  result: { errorCode?: string | null; errorMeta?: Record<string, unknown> | null },
  opts: { runId?: string | null; now?: Date } = {},
): UsageLimitState | null {
  if (result.errorCode !== USAGE_LIMIT_ERROR_CODE) return null;
  const now = opts.now ?? new Date();
  const meta = asRecord(result.errorMeta);

  const parsedReset = asTrimmedString(meta.usageLimitResetAt);
  const resetAt = parsedReset ? new Date(parsedReset) : null;
  const usableReset =
    resetAt && !Number.isNaN(resetAt.getTime()) && resetAt.getTime() > now.getTime()
      ? resetAt
      : new Date(now.getTime() + USAGE_LIMIT_FALLBACK_BACKOFF_MS);

  return {
    resetAt: usableReset.toISOString(),
    scope: asTrimmedString(meta.usageLimitScope),
    resetText: asTrimmedString(meta.usageLimitResetText),
    observedAt: now.toISOString(),
    runId: opts.runId ?? null,
  };
}

/** The stored limit, if one is stored and has not yet lifted. */
export function activeUsageLimit(
  stateJson: unknown,
  now: Date = new Date(),
): UsageLimitState | null {
  const stored = asRecord(asRecord(stateJson).usageLimit);
  const resetAt = asTrimmedString(stored.resetAt);
  if (!resetAt) return null;
  const parsed = new Date(resetAt);
  if (Number.isNaN(parsed.getTime()) || parsed.getTime() <= now.getTime()) return null;
  return {
    resetAt,
    scope: asTrimmedString(stored.scope),
    resetText: asTrimmedString(stored.resetText),
    observedAt: asTrimmedString(stored.observedAt) ?? resetAt,
    runId: asTrimmedString(stored.runId),
  };
}

/** Operator-facing reason, carrying the wait so the board shows why it is quiet. */
export function usageLimitBlockReason(limit: UsageLimitState): string {
  const scope = limit.scope ? `${limit.scope} usage limit` : "usage limit";
  return `Agent is waiting out its ${scope}; wakes resume at ${limit.resetAt}.`;
}
