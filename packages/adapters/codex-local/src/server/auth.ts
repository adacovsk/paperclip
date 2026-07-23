import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export function codexHomeDir(): string {
  const fromEnv = process.env.CODEX_HOME;
  if (typeof fromEnv === "string" && fromEnv.trim().length > 0) return fromEnv.trim();
  return path.join(os.homedir(), ".codex");
}

interface CodexLegacyAuthFile {
  accessToken?: string | null;
  accountId?: string | null;
}

interface CodexTokenBlock {
  id_token?: string | null;
  access_token?: string | null;
  refresh_token?: string | null;
  account_id?: string | null;
}

interface CodexModernAuthFile {
  OPENAI_API_KEY?: string | null;
  tokens?: CodexTokenBlock | null;
  last_refresh?: string | null;
}

export interface CodexAuthInfo {
  accessToken: string;
  accountId: string | null;
  refreshToken: string | null;
  idToken: string | null;
  email: string | null;
  planType: string | null;
  lastRefresh: string | null;
}

function base64UrlDecode(input: string): string | null {
  try {
    let normalized = input.replace(/-/g, "+").replace(/_/g, "/");
    const remainder = normalized.length % 4;
    if (remainder > 0) normalized += "=".repeat(4 - remainder);
    return Buffer.from(normalized, "base64").toString("utf8");
  } catch {
    return null;
  }
}

function decodeJwtPayload(token: string | null | undefined): Record<string, unknown> | null {
  if (typeof token !== "string" || token.trim().length === 0) return null;
  const parts = token.split(".");
  if (parts.length < 2) return null;
  const decoded = base64UrlDecode(parts[1] ?? "");
  if (!decoded) return null;
  try {
    const parsed = JSON.parse(decoded) as unknown;
    return typeof parsed === "object" && parsed !== null ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function readNestedString(record: Record<string, unknown>, pathSegments: string[]): string | null {
  let current: unknown = record;
  for (const segment of pathSegments) {
    if (typeof current !== "object" || current === null || Array.isArray(current)) return null;
    current = (current as Record<string, unknown>)[segment];
  }
  return typeof current === "string" && current.trim().length > 0 ? current.trim() : null;
}

function parsePlanAndEmailFromToken(idToken: string | null, accessToken: string | null): {
  email: string | null;
  planType: string | null;
} {
  const payloads = [decodeJwtPayload(idToken), decodeJwtPayload(accessToken)].filter(
    (value): value is Record<string, unknown> => value != null,
  );
  for (const payload of payloads) {
    const directEmail = typeof payload.email === "string" ? payload.email : null;
    const authBlock =
      typeof payload["https://api.openai.com/auth"] === "object" &&
      payload["https://api.openai.com/auth"] !== null &&
      !Array.isArray(payload["https://api.openai.com/auth"])
        ? payload["https://api.openai.com/auth"] as Record<string, unknown>
        : null;
    const profileBlock =
      typeof payload["https://api.openai.com/profile"] === "object" &&
      payload["https://api.openai.com/profile"] !== null &&
      !Array.isArray(payload["https://api.openai.com/profile"])
        ? payload["https://api.openai.com/profile"] as Record<string, unknown>
        : null;
    const email =
      directEmail
      ?? (typeof profileBlock?.email === "string" ? profileBlock.email : null)
      ?? (typeof authBlock?.chatgpt_user_email === "string" ? authBlock.chatgpt_user_email : null);
    const planType =
      typeof authBlock?.chatgpt_plan_type === "string" ? authBlock.chatgpt_plan_type : null;
    if (email || planType) return { email: email ?? null, planType };
  }
  return { email: null, planType: null };
}

export async function readCodexAuthInfo(codexHome?: string): Promise<CodexAuthInfo | null> {
  const authPath = path.join(codexHome ?? codexHomeDir(), "auth.json");
  let raw: string;
  try {
    raw = await fs.readFile(authPath, "utf8");
  } catch {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const obj = parsed as Record<string, unknown>;
  const modern = obj as CodexModernAuthFile;
  const legacy = obj as CodexLegacyAuthFile;

  const accessToken =
    legacy.accessToken
    ?? modern.tokens?.access_token
    ?? readNestedString(obj, ["tokens", "access_token"]);
  if (typeof accessToken !== "string" || accessToken.length === 0) return null;

  const accountId =
    legacy.accountId
    ?? modern.tokens?.account_id
    ?? readNestedString(obj, ["tokens", "account_id"]);
  const refreshToken =
    modern.tokens?.refresh_token
    ?? readNestedString(obj, ["tokens", "refresh_token"]);
  const idToken =
    modern.tokens?.id_token
    ?? readNestedString(obj, ["tokens", "id_token"]);
  const { email, planType } = parsePlanAndEmailFromToken(idToken, accessToken);

  return {
    accessToken,
    accountId:
      typeof accountId === "string" && accountId.trim().length > 0 ? accountId.trim() : null,
    refreshToken:
      typeof refreshToken === "string" && refreshToken.trim().length > 0 ? refreshToken.trim() : null,
    idToken:
      typeof idToken === "string" && idToken.trim().length > 0 ? idToken.trim() : null,
    email,
    planType,
    lastRefresh:
      typeof modern.last_refresh === "string" && modern.last_refresh.trim().length > 0
        ? modern.last_refresh.trim()
        : null,
  };
}
