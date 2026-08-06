import { createHash } from "node:crypto";

const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/gu;
const CONTROL_CHAR = /[\u0000-\u001f\u007f-\u009f]/u;
const RFC3339_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u;

/**
 * Irreversible fingerprint for logs. Never log raw IDs/title/body/token.
 * @param {string} value
 * @returns {string}
 */
export function fingerprint(value) {
  const input = typeof value === "string" ? value : "";
  return createHash("sha256").update(input, "utf8").digest("hex").slice(0, 16);
}

/**
 * Event dedup key: SHA-256(serverId + NUL + agentId + NUL + reason + NUL + timestamp)
 * @param {{ serverId: string, agentId: string, reason: string, timestamp: string }} parts
 */
export function eventFingerprint(parts) {
  const material = [parts.serverId, parts.agentId, parts.reason, parts.timestamp].join("\0");
  return createHash("sha256").update(material, "utf8").digest("hex");
}

/**
 * Outbox / display identity: SHA-256(serverId + NUL + agentId)
 * @param {{ serverId: string, agentId: string }} parts
 */
export function agentKey(parts) {
  const material = [parts.serverId, parts.agentId].join("\0");
  return createHash("sha256").update(material, "utf8").digest("hex");
}

/**
 * Strip control characters and truncate by Unicode code points.
 * @param {unknown} value
 * @param {string} fallback
 * @param {number} maxCodePoints
 */
export function sanitizeText(value, fallback, maxCodePoints) {
  const raw = typeof value === "string" ? value : "";
  const cleaned = raw.replace(CONTROL_CHARS, " ").replace(/\s+/gu, " ").trim() || fallback;
  const chars = [...cleaned];
  if (chars.length <= maxCodePoints) {
    return cleaned;
  }
  return `${chars.slice(0, Math.max(0, maxCodePoints - 1)).join("").trimEnd()}…`;
}

/**
 * Opaque route ID validation: non-empty, <=256, no control characters.
 * @param {unknown} value
 * @returns {value is string}
 */
export function isValidOpaqueId(value) {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 256) return false;
  if (CONTROL_CHAR.test(trimmed)) return false;
  return trimmed === value || trimmed.length > 0;
}

/**
 * Normalize opaque ID (trim). Returns null if invalid.
 * @param {unknown} value
 * @returns {string | null}
 */
export function normalizeOpaqueId(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 256) return null;
  if (/[\u0000-\u001f\u007f-\u009f]/u.test(trimmed)) return null;
  return trimmed;
}

/**
 * ISO-8601 timestamp validation. Rejects invalid/future (with small skew).
 * @param {unknown} value
 * @param {{ now?: number, futureSkewMs?: number }} [options]
 * @returns {{ ok: true, ms: number, iso: string } | { ok: false, reason: string }}
 */
export function parseAttentionTimestamp(value, options = {}) {
  if (typeof value !== "string" || !value.trim()) {
    return { ok: false, reason: "missing" };
  }
  const input = value.trim();
  if (!RFC3339_TIMESTAMP.test(input)) {
    return { ok: false, reason: "invalid" };
  }
  const ms = Date.parse(input);
  if (!Number.isFinite(ms)) {
    return { ok: false, reason: "invalid" };
  }
  const now = options.now ?? Date.now();
  const skew = options.futureSkewMs ?? 0;
  if (ms > now + skew) {
    return { ok: false, reason: "future" };
  }
  return { ok: true, ms, iso: new Date(ms).toISOString() };
}

/**
 * Structured logger that never accepts free-form secret fields.
 * @param {{ info?: Function, warn?: Function, error?: Function }} [sink]
 */
export function createLogger(sink = console) {
  const write = (level, event, fields = {}) => {
    const safe = {
      ts: new Date().toISOString(),
      level,
      event,
      ...fields,
    };
    // Hard ban on common secret field names
    for (const banned of ["token", "password", "title", "body", "summary", "endpoint", "route", "serverId", "workspaceId", "agentId"]) {
      if (Object.prototype.hasOwnProperty.call(safe, banned)) {
        delete safe[banned];
      }
    }
    const line = JSON.stringify(safe);
    if (level === "error") sink.error?.(line);
    else if (level === "warn") sink.warn?.(line);
    else sink.info?.(line);
  };
  return {
    info: (event, fields) => write("info", event, fields),
    warn: (event, fields) => write("warn", event, fields),
    error: (event, fields) => write("error", event, fields),
  };
}
