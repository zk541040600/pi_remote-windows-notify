import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const DEFAULT_TIMEOUT_MS = 4000;
const MIN_TIMEOUT_MS = 1000;
const MAX_TIMEOUT_MS = 15000;
const DEFAULT_HEALTH_INTERVAL_MS = 5000;
const DEFAULT_LEASE_STALE_MS = 15000;
const DEFAULT_FINISHED_TTL_MS = 30 * 60 * 1000;
const DEFAULT_BACKOFF_INITIAL_MS = 1000;
const DEFAULT_BACKOFF_MAX_MS = 60000;
const DEFAULT_GLOBAL_CONCURRENCY = 4;
const DEFAULT_TITLE_MAX = 72;
const DEFAULT_BODY_MAX = 220;

/**
 * @typedef {object} SenderConfig
 * @property {boolean} enabled
 * @property {"shadow" | "live"} deliveryMode
 * @property {string} daemonUrl
 * @property {string} clientId
 * @property {string} [daemonPassword]
 * @property {string} windowsEndpoint
 * @property {string} windowsToken
 * @property {number} timeoutMs
 * @property {string} stateDir
 * @property {number} healthIntervalMs
 * @property {number} leaseStaleMs
 * @property {number} finishedTtlMs
 * @property {number} backoffInitialMs
 * @property {number} backoffMaxMs
 * @property {number} globalConcurrency
 * @property {boolean} detailedSummary
 * @property {number} titleMaxCodePoints
 * @property {number} bodyMaxCodePoints
 * @property {string} [agentDisplayNameFallback]
 * @property {string} configPath
 */

function envString(name) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function isTruthy(value) {
  if (value === true) return true;
  if (typeof value !== "string") return false;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function clampInt(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function isLoopbackHostname(hostnameValue) {
  const value = hostnameValue.toLowerCase().replace(/^\[|\]$/g, "");
  return value === "localhost" || value === "::1" || /^127(?:\.\d{1,3}){3}$/.test(value);
}

/**
 * Endpoint policy: loopback HTTP/HTTPS always; non-loopback only HTTPS + opt-in.
 * @param {string} endpoint
 */
export function applyEndpointPolicy(endpoint) {
  let parsed;
  try {
    parsed = new URL(endpoint);
  } catch {
    return { allowed: false, reason: "invalid-url" };
  }
  if (parsed.username || parsed.password) {
    return { allowed: false, reason: "url-credentials" };
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return { allowed: false, reason: "protocol" };
  }
  if (isLoopbackHostname(parsed.hostname)) {
    return { allowed: true, reason: "loopback" };
  }
  if (parsed.protocol !== "https:" || !isTruthy(process.env.PASEO_SENDER_ALLOW_NONLOCAL)) {
    return { allowed: false, reason: "nonlocal" };
  }
  return { allowed: true, reason: "nonlocal-opt-in" };
}

/** Daemon transport policy: ws only on loopback; remote requires wss opt-in. */
export function applyDaemonUrlPolicy(endpoint) {
  let parsed;
  try {
    parsed = new URL(endpoint);
  } catch {
    return { allowed: false, reason: "invalid-url" };
  }
  if (parsed.username || parsed.password) return { allowed: false, reason: "url-credentials" };
  if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
    return { allowed: false, reason: "protocol" };
  }
  if (isLoopbackHostname(parsed.hostname)) return { allowed: true, reason: "loopback" };
  if (parsed.protocol !== "wss:" || !isTruthy(process.env.PASEO_SENDER_ALLOW_NONLOCAL)) {
    return { allowed: false, reason: "nonlocal" };
  }
  return { allowed: true, reason: "nonlocal-opt-in" };
}

function defaultStateDir() {
  const xdg = envString("XDG_STATE_HOME") || join(homedir(), ".local", "state");
  return join(xdg, "paseo-sender");
}

function defaultConfigPaths() {
  const xdg = envString("XDG_CONFIG_HOME") || join(homedir(), ".config");
  return [
    envString("PASEO_SENDER_CONFIG"),
    join(xdg, "paseo-sender", "config.json"),
    join(homedir(), ".paseo-sender", "config.json"),
  ].filter(Boolean);
}

/**
 * @param {unknown} file
 */
function isConfigShapeValid(file) {
  if (!file || typeof file !== "object" || Array.isArray(file)) return false;
  const f = /** @type {Record<string, unknown>} */ (file);
  for (const key of ["enabled", "detailedSummary"]) {
    if (f[key] !== undefined && typeof f[key] !== "boolean") return false;
  }
  for (const key of [
    "daemonUrl",
    "clientId",
    "daemonPassword",
    "windowsEndpoint",
    "windowsToken",
    "stateDir",
    "deliveryMode",
    "agentDisplayNameFallback",
  ]) {
    if (f[key] !== undefined && typeof f[key] !== "string") return false;
  }
  for (const key of [
    "timeoutMs",
    "healthIntervalMs",
    "leaseStaleMs",
    "finishedTtlMs",
    "backoffInitialMs",
    "backoffMaxMs",
    "globalConcurrency",
    "titleMaxCodePoints",
    "bodyMaxCodePoints",
  ]) {
    if (f[key] !== undefined && typeof f[key] !== "number") return false;
  }
  if (f.deliveryMode !== undefined && f.deliveryMode !== "shadow" && f.deliveryMode !== "live") {
    return false;
  }
  return true;
}

/**
 * @returns {Promise<{ file: Record<string, unknown>, path: string }>}
 */
export async function loadConfigFile(explicitPath) {
  const paths = explicitPath ? [explicitPath] : defaultConfigPaths();
  const seen = new Set();
  for (const candidate of paths) {
    const configPath = resolve(candidate);
    if (seen.has(configPath)) continue;
    seen.add(configPath);
    let raw;
    try {
      raw = await readFile(configPath, "utf8");
    } catch (error) {
      const missing = /** @type {{ code?: string }} */ (error)?.code === "ENOENT";
      if (missing && explicitPath) {
        throw new Error(`explicit config missing: ${configPath}`);
      }
      if (missing) continue;
      throw new Error(`config unreadable: ${configPath}`);
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new Error(`config invalid JSON: ${configPath}`);
    }
    if (!isConfigShapeValid(parsed)) {
      throw new Error(`config invalid shape: ${configPath}`);
    }
    const containsSecret =
      (typeof parsed.windowsToken === "string" && parsed.windowsToken.length > 0) ||
      (typeof parsed.daemonPassword === "string" && parsed.daemonPassword.length > 0);
    if (containsSecret && process.platform !== "win32") {
      const mode = (await stat(configPath)).mode & 0o777;
      if (mode !== 0o600) throw new Error(`config secret file mode must be 0600: ${configPath}`);
    }
    return { file: /** @type {Record<string, unknown>} */ (parsed), path: configPath };
  }
  return { file: {}, path: "" };
}

/**
 * Resolve runtime config. Env overrides file. Defaults to shadow mode.
 * @param {{ configPath?: string, overrides?: Partial<SenderConfig> }} [options]
 * @returns {Promise<SenderConfig>}
 */
export async function loadSenderConfig(options = {}) {
  const loaded = await loadConfigFile(options.configPath || envString("PASEO_SENDER_CONFIG") || undefined);
  const file = loaded.file;

  const windowsEndpoint =
    envString("PASEO_SENDER_WINDOWS_ENDPOINT") ||
    (typeof file.windowsEndpoint === "string" ? file.windowsEndpoint : "") ||
    "http://127.0.0.1:23118/notify";
  const endpointPolicy = applyEndpointPolicy(windowsEndpoint);

  const deliveryModeRaw =
    envString("PASEO_SENDER_DELIVERY_MODE") ||
    (typeof file.deliveryMode === "string" ? file.deliveryMode : "shadow");
  const deliveryMode = deliveryModeRaw === "live" ? "live" : "shadow";

  const enabled =
    file.enabled !== false &&
    !isTruthy(process.env.PASEO_SENDER_DISABLED) &&
    endpointPolicy.allowed;

  /** @type {SenderConfig} */
  const config = {
    enabled,
    deliveryMode,
    daemonUrl:
      envString("PASEO_SENDER_DAEMON_URL") ||
      (typeof file.daemonUrl === "string" ? file.daemonUrl : "") ||
      "ws://127.0.0.1:8787",
    clientId:
      envString("PASEO_SENDER_CLIENT_ID") ||
      (typeof file.clientId === "string" ? file.clientId : "") ||
      "paseo-sender",
    daemonPassword:
      envString("PASEO_SENDER_DAEMON_PASSWORD") ||
      (typeof file.daemonPassword === "string" ? file.daemonPassword : "") ||
      undefined,
    windowsEndpoint,
    windowsToken:
      envString("PASEO_SENDER_WINDOWS_TOKEN") ||
      (typeof file.windowsToken === "string" ? file.windowsToken : "") ||
      "",
    timeoutMs: clampInt(
      envString("PASEO_SENDER_TIMEOUT_MS") || file.timeoutMs || DEFAULT_TIMEOUT_MS,
      MIN_TIMEOUT_MS,
      MAX_TIMEOUT_MS,
      DEFAULT_TIMEOUT_MS,
    ),
    stateDir:
      envString("PASEO_SENDER_STATE_DIR") ||
      (typeof file.stateDir === "string" ? file.stateDir : "") ||
      defaultStateDir(),
    healthIntervalMs: clampInt(
      envString("PASEO_SENDER_HEALTH_INTERVAL_MS") || file.healthIntervalMs || DEFAULT_HEALTH_INTERVAL_MS,
      1000,
      30000,
      DEFAULT_HEALTH_INTERVAL_MS,
    ),
    leaseStaleMs: clampInt(
      envString("PASEO_SENDER_LEASE_STALE_MS") || file.leaseStaleMs || DEFAULT_LEASE_STALE_MS,
      3000,
      120000,
      DEFAULT_LEASE_STALE_MS,
    ),
    finishedTtlMs: clampInt(
      file.finishedTtlMs || DEFAULT_FINISHED_TTL_MS,
      60_000,
      24 * 60 * 60 * 1000,
      DEFAULT_FINISHED_TTL_MS,
    ),
    backoffInitialMs: clampInt(
      file.backoffInitialMs || DEFAULT_BACKOFF_INITIAL_MS,
      100,
      10000,
      DEFAULT_BACKOFF_INITIAL_MS,
    ),
    backoffMaxMs: clampInt(
      file.backoffMaxMs || DEFAULT_BACKOFF_MAX_MS,
      1000,
      300000,
      DEFAULT_BACKOFF_MAX_MS,
    ),
    globalConcurrency: clampInt(
      file.globalConcurrency || DEFAULT_GLOBAL_CONCURRENCY,
      1,
      16,
      DEFAULT_GLOBAL_CONCURRENCY,
    ),
    detailedSummary:
      isTruthy(process.env.PASEO_SENDER_DETAILED_SUMMARY) || file.detailedSummary === true,
    titleMaxCodePoints: clampInt(file.titleMaxCodePoints || DEFAULT_TITLE_MAX, 8, 72, DEFAULT_TITLE_MAX),
    bodyMaxCodePoints: clampInt(file.bodyMaxCodePoints || DEFAULT_BODY_MAX, 8, 220, DEFAULT_BODY_MAX),
    agentDisplayNameFallback:
      (typeof file.agentDisplayNameFallback === "string" && file.agentDisplayNameFallback) || "Agent",
    configPath: loaded.path,
    ...options.overrides,
  };

  const finalEndpointPolicy = applyEndpointPolicy(config.windowsEndpoint);
  if (!finalEndpointPolicy.allowed) {
    throw new Error(`Windows endpoint rejected: ${finalEndpointPolicy.reason}`);
  }
  const daemonPolicy = applyDaemonUrlPolicy(config.daemonUrl);
  if (!daemonPolicy.allowed) throw new Error(`daemon URL rejected: ${daemonPolicy.reason}`);
  if (!config.clientId || config.clientId.length > 256 || /[\u0000-\u001f\u007f-\u009f]/u.test(config.clientId)) {
    throw new Error("clientId rejected");
  }
  if (config.enabled && config.deliveryMode === "live" && !config.windowsToken) {
    throw new Error("live delivery requires Windows token");
  }
  config.stateDir = resolve(config.stateDir);
  config.enabled = enabled && config.enabled !== false;
  return config;
}

/**
 * Redacted status view — never includes secrets.
 * @param {SenderConfig} config
 */
export function publicConfigStatus(config) {
  return {
    enabled: config.enabled,
    deliveryMode: config.deliveryMode,
    daemonUrlHost: safeHost(config.daemonUrl),
    windowsEndpointHost: safeHost(config.windowsEndpoint),
    hasWindowsToken: Boolean(config.windowsToken),
    hasDaemonPassword: Boolean(config.daemonPassword),
    stateDir: config.stateDir,
    timeoutMs: config.timeoutMs,
    healthIntervalMs: config.healthIntervalMs,
    leaseStaleMs: config.leaseStaleMs,
    detailedSummary: config.detailedSummary,
    configPath: config.configPath || "(defaults)",
  };
}

function safeHost(urlValue) {
  try {
    const u = new URL(urlValue);
    return `${u.protocol}//${u.hostname}${u.port ? `:${u.port}` : ""}${u.pathname}`;
  } catch {
    return "(invalid)";
  }
}

export const CONFIG_DEFAULTS = {
  DEFAULT_TIMEOUT_MS,
  DEFAULT_HEALTH_INTERVAL_MS,
  DEFAULT_LEASE_STALE_MS,
  DEFAULT_FINISHED_TTL_MS,
  DEFAULT_BACKOFF_INITIAL_MS,
  DEFAULT_BACKOFF_MAX_MS,
};
