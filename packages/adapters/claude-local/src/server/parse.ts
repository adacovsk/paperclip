import type { UsageSummary } from "@paperclipai/adapter-utils";
import { asString, asNumber, parseObject, parseJson } from "@paperclipai/adapter-utils/server-utils";

const CLAUDE_AUTH_REQUIRED_RE = /(?:not\s+logged\s+in|please\s+log\s+in|please\s+run\s+`?claude\s+login`?|login\s+required|requires\s+login|unauthorized|authentication\s+required)/i;
const URL_RE = /(https?:\/\/[^\s'"`<>()[\]{};,!?]+[^\s'"`<>()[\]{};,!.?:]+)/gi;

/**
 * Largest context the model was asked to carry at any single turn of this run.
 *
 * Session rotation is decided *between* runs, from the previous run's totals, so
 * nothing has ever been able to see growth that happens *inside* one run — and
 * that is the shape that actually fails. One Worker run reached 17.2M cached
 * input tokens with `sessionRotated: false` and terminated `adapter_failed`: the
 * session did not die and get replaced, it grew unbounded within a single run
 * until the adapter refused it. No `maxRawInputTokens` value could have caught
 * that, because the run began under threshold.
 *
 * This measures the condition without acting on it. A within-run kill/rotate
 * guard is buildable on the same numbers, but killing a Worker mid-task on a
 * mis-set ceiling is worse than the failure it prevents, and the failure is
 * currently a sample of one. Measure first.
 */
function peakContextTokensOf(message: Record<string, unknown>): number {
  const usage = parseObject(message.usage);
  return (
    asNumber(usage.input_tokens, 0) +
    asNumber(usage.cache_read_input_tokens, 0) +
    asNumber(usage.cache_creation_input_tokens, 0)
  );
}

export function parseClaudeStreamJson(stdout: string) {
  let sessionId: string | null = null;
  let model = "";
  let finalResult: Record<string, unknown> | null = null;
  let peakContextTokens = 0;
  const assistantTexts: string[] = [];

  for (const rawLine of stdout.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    const event = parseJson(line);
    if (!event) continue;

    const type = asString(event.type, "");
    if (type === "system" && asString(event.subtype, "") === "init") {
      sessionId = asString(event.session_id, sessionId ?? "") || sessionId;
      model = asString(event.model, model);
      continue;
    }

    if (type === "assistant") {
      sessionId = asString(event.session_id, sessionId ?? "") || sessionId;
      const message = parseObject(event.message);
      peakContextTokens = Math.max(peakContextTokens, peakContextTokensOf(message));
      const content = Array.isArray(message.content) ? message.content : [];
      for (const entry of content) {
        if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue;
        const block = entry as Record<string, unknown>;
        if (asString(block.type, "") === "text") {
          const text = asString(block.text, "");
          if (text) assistantTexts.push(text);
        }
      }
      continue;
    }

    if (type === "result") {
      finalResult = event;
      sessionId = asString(event.session_id, sessionId ?? "") || sessionId;
    }
  }

  if (!finalResult) {
    // No `result` event: the run was killed or refused mid-stream. This is the
    // case peakContextTokens exists for, so it is returned here too — a failed
    // run's turn-by-turn usage is the only record of how big it got.
    return {
      sessionId,
      model,
      costUsd: null as number | null,
      usage: null as UsageSummary | null,
      peakContextTokens,
      summary: assistantTexts.join("\n\n").trim(),
      resultJson: null as Record<string, unknown> | null,
    };
  }

  const usageObj = parseObject(finalResult.usage);
  const usage: UsageSummary = {
    inputTokens: asNumber(usageObj.input_tokens, 0),
    cachedInputTokens: asNumber(usageObj.cache_read_input_tokens, 0),
    outputTokens: asNumber(usageObj.output_tokens, 0),
  };
  const costRaw = finalResult.total_cost_usd;
  const costUsd = typeof costRaw === "number" && Number.isFinite(costRaw) ? costRaw : null;
  const summary = asString(finalResult.result, assistantTexts.join("\n\n")).trim();

  return {
    sessionId,
    model,
    costUsd,
    usage,
    peakContextTokens,
    summary,
    resultJson: finalResult,
  };
}

function extractClaudeErrorMessages(parsed: Record<string, unknown>): string[] {
  const raw = Array.isArray(parsed.errors) ? parsed.errors : [];
  const messages: string[] = [];

  for (const entry of raw) {
    if (typeof entry === "string") {
      const msg = entry.trim();
      if (msg) messages.push(msg);
      continue;
    }

    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      continue;
    }

    const obj = entry as Record<string, unknown>;
    const msg = asString(obj.message, "") || asString(obj.error, "") || asString(obj.code, "");
    if (msg) {
      messages.push(msg);
      continue;
    }

    try {
      messages.push(JSON.stringify(obj));
    } catch {
      // skip non-serializable entry
    }
  }

  return messages;
}

export function extractClaudeLoginUrl(text: string): string | null {
  const match = text.match(URL_RE);
  if (!match || match.length === 0) return null;
  for (const rawUrl of match) {
    const cleaned = rawUrl.replace(/[\])}.!,?;:'\"]+$/g, "");
    if (cleaned.includes("claude") || cleaned.includes("anthropic") || cleaned.includes("auth")) {
      return cleaned;
    }
  }
  return match[0]?.replace(/[\])}.!,?;:'\"]+$/g, "") ?? null;
}

export function detectClaudeLoginRequired(input: {
  parsed: Record<string, unknown> | null;
  stdout: string;
  stderr: string;
}): { requiresLogin: boolean; loginUrl: string | null } {
  const resultText = asString(input.parsed?.result, "").trim();
  const messages = [resultText, ...extractClaudeErrorMessages(input.parsed ?? {}), input.stdout, input.stderr]
    .join("\n")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const requiresLogin = messages.some((line) => CLAUDE_AUTH_REQUIRED_RE.test(line));
  return {
    requiresLogin,
    loginUrl: extractClaudeLoginUrl([input.stdout, input.stderr].join("\n")),
  };
}

/**
 * A usage limit is a wall-clock wait, not a failure to retry.
 *
 * The CLI reports it through an ordinary `result` event — `subtype: success`,
 * non-zero exit, the limit text in `result` — so nothing distinguishes it from a
 * crash, and a scheduled agent re-fires into it every interval. One fleet burned
 * 46 runs over ~17h that way, 35 of them one agent's cron hitting the same hard
 * error, each a fresh process launch against a limit with a known reset time.
 *
 * Two shapes are emitted, and the zone is parenthesised when present:
 *   You've hit your weekly limit · resets 8pm (America/Denver)
 *   You've hit your usage limit · resets 3:30pm
 */
const CLAUDE_USAGE_LIMIT_RE =
  /(?:hit|reached|exceeded)\s+(?:your|the)\s+(?:(weekly|monthly|daily)\s+)?(?:usage\s+)?limit|usage\s+limit\s+reached|rate\s+limit\s+exceeded/i;
const CLAUDE_LIMIT_RESET_RE =
  /resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([A-Za-z_]+\/[A-Za-z_+-]+)\))?/i;

export type ClaudeUsageLimit = {
  limited: boolean;
  /** The limit window the message named, when it named one. */
  scope: string | null;
  /** When the limit lifts, as an ISO string, or null when the text carried no time. */
  resetAt: string | null;
  /** The matched text, kept verbatim for the operator-facing error message. */
  resetText: string | null;
};

/**
 * The next instant at which it is `hour:minute` in `timeZone`.
 *
 * `Intl` is the only zone database available here, so the offset is read back
 * out of a formatted timestamp rather than computed. Across a DST boundary the
 * offset that applies is the one at the *target* instant, which is why the
 * offset is resolved from a first guess and then re-applied.
 */
function nextWallClockInZone(hour: number, minute: number, timeZone: string | null, now: Date): Date | null {
  const zone = timeZone ?? "UTC";
  const offsetAt = (instant: Date): number | null => {
    try {
      const parts = new Intl.DateTimeFormat("en-US", {
        timeZone: zone,
        hour12: false,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      }).formatToParts(instant);
      const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? NaN);
      const asUtc = Date.UTC(
        get("year"),
        get("month") - 1,
        get("day"),
        get("hour") % 24,
        get("minute"),
        get("second"),
      );
      if (!Number.isFinite(asUtc)) return null;
      return asUtc - instant.getTime();
    } catch {
      return null;
    }
  };

  const initialOffset = offsetAt(now);
  if (initialOffset === null) return null;

  const localNow = new Date(now.getTime() + initialOffset);
  const candidateLocal = Date.UTC(
    localNow.getUTCFullYear(),
    localNow.getUTCMonth(),
    localNow.getUTCDate(),
    hour,
    minute,
    0,
  );
  const dayMs = 24 * 60 * 60 * 1000;
  for (const local of [candidateLocal, candidateLocal + dayMs]) {
    const guess = new Date(local - initialOffset);
    const settledOffset = offsetAt(guess) ?? initialOffset;
    const resolved = new Date(local - settledOffset);
    if (resolved.getTime() > now.getTime()) return resolved;
  }
  return null;
}

export function detectClaudeUsageLimit(input: {
  parsed: Record<string, unknown> | null;
  stdout: string;
  stderr: string;
  now?: Date;
}): ClaudeUsageLimit {
  const resultText = asString(input.parsed?.result, "").trim();
  const messages = [resultText, ...extractClaudeErrorMessages(input.parsed ?? {}), input.stdout, input.stderr]
    .join("\n")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const hit = messages.find((line) => CLAUDE_USAGE_LIMIT_RE.test(line));
  if (!hit) return { limited: false, scope: null, resetAt: null, resetText: null };

  const scope = hit.match(CLAUDE_USAGE_LIMIT_RE)?.[1]?.toLowerCase() ?? null;
  const reset = hit.match(CLAUDE_LIMIT_RESET_RE);
  if (!reset) return { limited: true, scope, resetAt: null, resetText: null };

  const meridiem = reset[3]?.toLowerCase();
  let hour = Number(reset[1]);
  if (meridiem === "pm" && hour < 12) hour += 12;
  if (meridiem === "am" && hour === 12) hour = 0;
  const minute = Number(reset[2] ?? 0);
  if (!Number.isFinite(hour) || hour > 23 || !Number.isFinite(minute) || minute > 59) {
    return { limited: true, scope, resetAt: null, resetText: reset[0] };
  }

  const resetAt = nextWallClockInZone(hour, minute, reset[4] ?? null, input.now ?? new Date());
  return { limited: true, scope, resetAt: resetAt?.toISOString() ?? null, resetText: reset[0] };
}

export function describeClaudeFailure(parsed: Record<string, unknown>): string | null {
  const subtype = asString(parsed.subtype, "");
  const resultText = asString(parsed.result, "").trim();
  const errors = extractClaudeErrorMessages(parsed);

  let detail = resultText;
  if (!detail && errors.length > 0) {
    detail = errors[0] ?? "";
  }

  const parts = ["Claude run failed"];
  if (subtype) parts.push(`subtype=${subtype}`);
  if (detail) parts.push(detail);
  return parts.length > 1 ? parts.join(": ") : null;
}

export function isClaudeMaxTurnsResult(parsed: Record<string, unknown> | null | undefined): boolean {
  if (!parsed) return false;

  const subtype = asString(parsed.subtype, "").trim().toLowerCase();
  if (subtype === "error_max_turns") return true;

  const stopReason = asString(parsed.stop_reason, "").trim().toLowerCase();
  if (stopReason === "max_turns") return true;

  const resultText = asString(parsed.result, "").trim();
  return /max(?:imum)?\s+turns?/i.test(resultText);
}

export function isClaudeUnknownSessionError(parsed: Record<string, unknown>): boolean {
  const resultText = asString(parsed.result, "").trim();
  const allMessages = [resultText, ...extractClaudeErrorMessages(parsed)]
    .map((msg) => msg.trim())
    .filter(Boolean);

  return allMessages.some((msg) =>
    /no conversation found with session id|unknown session|session .* not found/i.test(msg),
  );
}
