function truncateSummaryText(value: unknown, maxLength = 500) {
  if (typeof value !== "string") return null;
  return value.length > maxLength ? value.slice(0, maxLength) : value;
}

function readNumericField(record: Record<string, unknown>, key: string) {
  return key in record ? record[key] ?? null : undefined;
}

export function summarizeHeartbeatRunResultJson(
  resultJson: Record<string, unknown> | null | undefined,
): Record<string, unknown> | null {
  if (!resultJson || typeof resultJson !== "object" || Array.isArray(resultJson)) {
    return null;
  }

  const summary: Record<string, unknown> = {};
  const textFields = ["summary", "result", "message", "error"] as const;
  for (const key of textFields) {
    const value = truncateSummaryText(resultJson[key]);
    if (value !== null) {
      summary[key] = value;
    }
  }

  // `num_turns` is kept for the same reason cost is: it is the only durable
  // record of how close a run came to `maxTurnsPerRun`. Without it a run that
  // dies at the cap leaves no evidence of where real runs land in the
  // distribution, so the cap can only ever be raised by guess -- and a raise
  // that is not measured is the intervention that has already failed once.
  const numericFieldAliases = ["total_cost_usd", "cost_usd", "costUsd", "num_turns", "numTurns"] as const;
  for (const key of numericFieldAliases) {
    const value = readNumericField(resultJson, key);
    if (value !== undefined && value !== null) {
      summary[key] = value;
    }
  }

  return Object.keys(summary).length > 0 ? summary : null;
}
