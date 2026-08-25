import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { hostname, homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type NotifyConfigFile = {
  enabled?: boolean;
  endpoint?: string;
  token?: string;
  timeoutMs?: number;
  title?: string;
  bodyTemplate?: string;
  messageMode?: "dynamic" | "static";
  remoteHostAlias?: string;
  /** Explicit origin override. Only "pi-web" enables Web exact routing for RPC. */
  originKind?: string;
  /** Pi Web instance UUID (opaque). Required with originKind=pi-web for Web exact fields. */
  instanceKey?: string;
  /**
   * Manual opt-in: when true (or PI_NOTIFY_PASEO_LEASE_GATE=1), a
   * PASEO_AGENT_ID-launched session assigns notification ownership to Paseo once.
   * Lease health remains diagnostic and never changes ownership mid-session.
   */
  paseoLeaseGateEnabled?: boolean;
  /** Override path to paseo-sender health.json (tests / non-default state dir). */
  paseoLeasePath?: string;
};

type RuntimeConfig = {
  enabled: boolean;
  endpoint: string;
  token: string;
  timeoutMs: number;
  title: string;
  bodyTemplate: string;
  messageMode: "dynamic" | "static";
  remoteHostAlias: string;
  /** True only when config/env explicitly set originKind=pi-web. */
  piWebOriginConfigured: boolean;
  /** Validated opaque instance key, or empty when absent/invalid. */
  instanceKey: string;
  /** Manual Paseo session-ownership gate (legacy config name; default false). */
  paseoLeaseGateEnabled: boolean;
  /** Absolute path to paseo-sender health lease file. */
  paseoLeasePath: string;
};

type AgentMessageLike = {
  role?: string;
  content?: unknown;
  toolName?: string;
  isError?: boolean;
};

type ContextSnapshot = {
  cwd: string;
  mode?: string;
  explicitSessionName?: string;
  displaySessionName?: string;
  sessionKey?: string;
  /**
   * Process-local only: used to compute routingKey at notify time.
   * Never include in notification payload, logs, or toast state.
   */
  rawSessionId?: string;
};

type NotificationKind = "ask-user" | "turn-complete";
type OriginKind = "terminal" | "pi-web";
type SessionNotificationOwner = "pi" | "paseo";

type NotifyRouteFields = {
  routeVersion: 1;
  notificationId: string;
  notificationKind: NotificationKind;
  originKind: OriginKind;
  instanceKey?: string;
  routingKey?: string;
};

type NotifyPayload = {
  title: string;
  body: string;
  focusTarget?: string;
  cwdBase?: string;
  tabTitle?: string;
  sessionName?: string;
} & NotifyRouteFields;

const DEFAULT_ENDPOINT = "http://127.0.0.1:23118/notify";
const DEFAULT_TIMEOUT_MS = 4000;
const DEFAULT_CONFIG_PATH = join(homedir(), ".pi", "agent", "remote-windows-notify.json");
const DEFAULT_PASEO_LEASE_STALE_MS = 15_000;
const PASEO_LEASE_SCHEMA_VERSION = 1;
const ASK_USER_PROMPT_EVENT = "rpiv:ask-user:prompt";
const PI_TERMINAL_TITLE = "π";
const MAX_CANONICAL_TITLE_BYTES = 144;
const SESSION_KEY_LENGTH = 12;
const ROUTE_VERSION = 1 as const;
const ROUTING_KEY_DOMAIN = "pi-web-route-v1";
const INSTANCE_KEY_MIN_LENGTH = 8;
const INSTANCE_KEY_MAX_LENGTH = 128;
const INSTANCE_KEY_PATTERN = /^[A-Za-z0-9._+-]+$/;
const INSTANCE_KEY_PADDING_PATTERN =
  /^[\u0009-\u000d\u0020]+|[\u0009-\u000d\u0020]+$/g;
const SESSION_ID_MIN_LENGTH = 1;
const SESSION_ID_MAX_LENGTH = 256;
const OSC_SEQUENCE_PATTERN = /(?:\u001b\]|\u009d)[\s\S]*?(?:\u0007|\u001b\\|\u009c|$)/gu;
const TERMINAL_STRING_PATTERN = /(?:\u001b[P^_X]|\u0090|\u0098|\u009e|\u009f)[\s\S]*?(?:\u001b\\|\u009c|$)/gu;
const CSI_SEQUENCE_PATTERN = /(?:\u001b\[|\u009b)[0-?]*[ -/]*[@-~]/gu;
const ESC_SEQUENCE_PATTERN = /\u001b(?:[ -/]*[@-~])?/gu;
const TITLE_CONTROL_PATTERN = /[\u0000-\u001f\u007f-\u009f]+/gu;
const BIDI_CONTROL_PATTERN = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]+/gu;

function isTruthy(value: string | undefined): boolean {
  return /^(1|true|yes|on)$/i.test((value ?? "").trim());
}

function configString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isPortableSessionWhitespaceCode(code: number): boolean {
  return (
    (code >= 0x0009 && code <= 0x000d) ||
    code === 0x0020 ||
    code === 0x0085 ||
    code === 0x00a0 ||
    code === 0x1680 ||
    (code >= 0x2000 && code <= 0x200a) ||
    code === 0x2028 ||
    code === 0x2029 ||
    code === 0x202f ||
    code === 0x205f ||
    code === 0x3000 ||
    code === 0xfeff
  );
}

function isValidPiWebSessionId(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length < SESSION_ID_MIN_LENGTH ||
    value.length > SESSION_ID_MAX_LENGTH
  ) {
    return false;
  }

  let hasNonWhitespace = false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (
      code < 0x20 ||
      (code >= 0x7f && code <= 0x9f) ||
      code === 0xfeff
    ) {
      return false;
    }
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) {
        return false;
      }
      hasNonWhitespace = true;
      index += 1;
      continue;
    }
    if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
    if (!isPortableSessionWhitespaceCode(code)) {
      hasNonWhitespace = true;
    }
  }

  return hasNonWhitespace && !value.includes("://");
}

function normalizeText(value: unknown, fallback: string, maxLength: number): string {
  const raw = typeof value === "string" ? value : "";
  const collapsed = raw.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  const next = collapsed || fallback;
  const characters = [...next];
  if (characters.length <= maxLength) {
    return next;
  }
  return `${characters.slice(0, Math.max(0, maxLength - 1)).join("").trimEnd()}…`;
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) {
    return value;
  }

  const ellipsis = "…";
  const contentBudget = Math.max(0, maxBytes - Buffer.byteLength(ellipsis, "utf8"));
  let bytes = 0;
  let prefix = "";
  for (const character of value) {
    const characterBytes = Buffer.byteLength(character, "utf8");
    if (bytes + characterBytes > contentBudget) {
      break;
    }
    prefix += character;
    bytes += characterBytes;
  }
  return `${prefix.trimEnd()}${ellipsis}`;
}

/**
 * routingKey = SHA-256("pi-web-route-v1\0" + instanceKey + "\0" + rawSessionId) as full lowercase hex.
 * Does not accept empty inputs; callers must fail-closed before invoking.
 */
export function computePiWebRoutingKey(instanceKey: string, rawSessionId: string): string {
  const normalizedInstanceKey = normalizeInstanceKey(instanceKey);
  if (!normalizedInstanceKey || normalizedInstanceKey !== instanceKey) {
    throw new Error("instanceKey is invalid");
  }
  if (!isValidPiWebSessionId(rawSessionId)) {
    throw new Error("rawSessionId is required");
  }
  return createHash("sha256")
    .update(ROUTING_KEY_DOMAIN)
    .update("\0")
    .update(instanceKey)
    .update("\0")
    .update(rawSessionId)
    .digest("hex");
}

function normalizeInstanceKey(value: unknown): string {
  const key =
    typeof value === "string"
      ? value.replace(INSTANCE_KEY_PADDING_PATTERN, "")
      : "";
  if (
    key.length < INSTANCE_KEY_MIN_LENGTH ||
    key.length > INSTANCE_KEY_MAX_LENGTH ||
    !INSTANCE_KEY_PATTERN.test(key)
  ) {
    return "";
  }
  return key;
}

function isExplicitPiWebOriginKind(value: unknown): boolean {
  return configString(value).toLowerCase() === "pi-web";
}

function isPiWebHostProcess(): boolean {
  // agegr Pi Web exports this marker when launched with its supported --no-open mode.
  // File-level pi-web routing remains scoped to that host; unrelated RPC processes stay terminal.
  return isTruthy(process.env.PI_WEB_NO_OPEN);
}

function readSessionIdentity(ctx: unknown): { rawSessionId?: string; sessionKey?: string } {
  try {
    const manager = (ctx as { sessionManager?: { getSessionId?: () => unknown } })?.sessionManager;
    const sessionId = manager?.getSessionId?.();
    if (!isValidPiWebSessionId(sessionId)) {
      return {};
    }
    const rawSessionId = sessionId;
    return {
      rawSessionId,
      sessionKey: createHash("sha256").update(rawSessionId).digest("hex").slice(0, SESSION_KEY_LENGTH),
    };
  } catch {
    return {};
  }
}

function renderBody(template: string, cwd: string): string {
  const cwdBase = basename(cwd) || cwd;
  return normalizeText(
    template
      .replace(/\{host\}/g, hostname())
      .replace(/\{cwd\}/g, cwd)
      .replace(/\{cwdBase\}/g, cwdBase),
    "Pi completed a turn",
    220,
  );
}

function extractTextContent(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }

  const parts: string[] = [];
  for (const item of content) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const maybeText = item as { type?: string; text?: string };
    if (maybeText.type === "text" && typeof maybeText.text === "string") {
      parts.push(maybeText.text);
    }
  }
  return parts.join(" ");
}

function findTextForRole(messages: AgentMessageLike[], role: string, fromEnd: boolean): string {
  const start = fromEnd ? messages.length - 1 : 0;
  const end = fromEnd ? -1 : messages.length;
  const step = fromEnd ? -1 : 1;
  for (let index = start; index !== end; index += step) {
    const message = messages[index];
    if (message?.role !== role) {
      continue;
    }
    const text = extractTextContent(message.content);
    if (text.trim()) {
      return text;
    }
  }
  return "";
}

function readContextSnapshot(ctx: unknown, messages: AgentMessageLike[] = []): ContextSnapshot {
  let cwd = process.cwd();
  let mode: string | undefined;
  let explicitSessionName: string | undefined;
  let firstSessionUserText = "";

  try {
    const context = ctx as { cwd?: unknown; mode?: unknown; sessionManager?: { getCwd?: () => unknown } };
    const managedCwd = context?.sessionManager?.getCwd?.();
    if (typeof managedCwd === "string" && managedCwd.trim()) {
      cwd = managedCwd;
    } else if (typeof context?.cwd === "string" && context.cwd.trim()) {
      cwd = context.cwd;
    }
    if (typeof context?.mode === "string") {
      mode = context.mode;
    }
  } catch {
  }

  try {
    const manager = (ctx as {
      sessionManager?: {
        getSessionName?: () => unknown;
        getBranch?: () => unknown;
      };
    })?.sessionManager;
    explicitSessionName = normalizeTabTitlePart(manager?.getSessionName?.(), "") || undefined;
    const branch = manager?.getBranch?.();
    if (Array.isArray(branch)) {
      for (const candidate of branch) {
        const entry = candidate as { type?: unknown; message?: { role?: unknown; content?: unknown } };
        if (entry?.type !== "message" || entry.message?.role !== "user") {
          continue;
        }
        firstSessionUserText = extractTextContent(entry.message.content);
        if (firstSessionUserText.trim()) {
          break;
        }
      }
    }
  } catch {
  }

  const displaySessionName = explicitSessionName ||
    normalizeText(firstSessionUserText, "", 96) ||
    normalizeText(findTextForRole(messages, "user", false), "", 96) ||
    undefined;
  const identity = readSessionIdentity(ctx);
  return {
    cwd,
    mode,
    explicitSessionName,
    displaySessionName,
    sessionKey: identity.sessionKey,
    rawSessionId: identity.rawSessionId,
  };
}

function collectToolInfo(messages: AgentMessageLike[]): {
  toolNames: string[];
  hasToolError: boolean;
  hasTrailingToolError: boolean;
} {
  const seen = new Set<string>();
  const toolNames: string[] = [];
  let hasToolError = false;
  let hasTrailingToolError = false;

  for (const message of messages) {
    if (message?.role !== "toolResult") {
      if (message?.role === "assistant" && extractTextContent(message.content).trim()) {
        hasTrailingToolError = false;
      }
      continue;
    }
    if (message.isError) {
      hasToolError = true;
      hasTrailingToolError = true;
    }
    const toolName = normalizeText(message.toolName, "", 32);
    if (!toolName || seen.has(toolName)) {
      continue;
    }
    seen.add(toolName);
    toolNames.push(toolName);
  }
  return { toolNames, hasToolError, hasTrailingToolError };
}

function assistantTextSignalsProblem(text: string): boolean {
  const value = text.trim();
  if (!value) {
    return false;
  }
  return (
    /(^|\n)\s*(❌|⚠️)/.test(value) ||
    /(?:测试|验证|构建|命令|执行|运行|提交|上传|push|commit|build|test|verify)\S{0,12}(?:失败|报错|未通过)/i.test(value) ||
    /(?:无法完成|未完成|不能继续|阻塞|需要你确认|需要确认)/.test(value) ||
    /\b(blocked|failed|failure|cannot continue|unable to complete)\b/i.test(value)
  );
}

function buildDynamicNotification(
  messages: AgentMessageLike[],
  config: RuntimeConfig,
  cwd: string,
  sessionName?: string,
): { title: string; body: string } {
  const userPrompt = normalizeText(findTextForRole(messages, "user", true), "", 72);
  const assistantText = normalizeText(findTextForRole(messages, "assistant", true), "", 120);
  const { toolNames, hasToolError, hasTrailingToolError } = collectToolInfo(messages);
  const title = normalizeText(sessionName || userPrompt || assistantText || config.title, "Pi", 72);
  const hasUnresolvedError = hasTrailingToolError || (hasToolError && assistantTextSignalsProblem(assistantText));
  const status = hasUnresolvedError ? "有报错，等你看" : toolNames.length > 0 ? "已完成，等你确认" : "已回复，等你输入";
  const bodyParts = [status];

  if (toolNames.length > 0) {
    bodyParts.push(`tools: ${toolNames.slice(0, 4).join(", ")}`);
  }
  bodyParts.push(assistantText && assistantText !== title ? assistantText : renderBody(config.bodyTemplate, cwd));
  return {
    title,
    body: normalizeText(bodyParts.join(" · "), renderBody(config.bodyTemplate, cwd), 220),
  };
}

function getExtensionConfigPaths(): string[] {
  const paths: string[] = [];
  let current = dirname(fileURLToPath(import.meta.url));
  while (true) {
    paths.push(join(current, "remote-windows-notify.json"));
    const parent = dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }
  return paths;
}

function isConfigShapeValid(file: NotifyConfigFile): boolean {
  if (file.enabled !== undefined && typeof file.enabled !== "boolean") return false;
  if (file.endpoint !== undefined && typeof file.endpoint !== "string") return false;
  if (file.token !== undefined && typeof file.token !== "string") return false;
  if (file.timeoutMs !== undefined && typeof file.timeoutMs !== "number") return false;
  if (file.title !== undefined && typeof file.title !== "string") return false;
  if (file.bodyTemplate !== undefined && typeof file.bodyTemplate !== "string") return false;
  if (file.messageMode !== undefined && file.messageMode !== "dynamic" && file.messageMode !== "static") return false;
  if (file.remoteHostAlias !== undefined && typeof file.remoteHostAlias !== "string") return false;
  if (file.originKind !== undefined && typeof file.originKind !== "string") return false;
  if (file.instanceKey !== undefined && typeof file.instanceKey !== "string") return false;
  if (file.paseoLeaseGateEnabled !== undefined && typeof file.paseoLeaseGateEnabled !== "boolean") return false;
  if (file.paseoLeasePath !== undefined && typeof file.paseoLeasePath !== "string") return false;
  return true;
}

async function loadConfigFile(): Promise<NotifyConfigFile> {
  const explicitPath = configString(process.env.PI_NOTIFY_CONFIG);
  const paths = [explicitPath, ...getExtensionConfigPaths(), DEFAULT_CONFIG_PATH].filter(Boolean);
  const seen = new Set<string>();

  for (const candidate of paths) {
    const configPath = resolve(candidate);
    if (seen.has(configPath)) {
      continue;
    }
    seen.add(configPath);

    let raw: string;
    try {
      raw = await readFile(configPath, "utf8");
    } catch (error) {
      const missing = (error as { code?: unknown })?.code === "ENOENT";
      if (missing && explicitPath && configPath === resolve(explicitPath)) {
        return { enabled: false };
      }
      if (missing) {
        continue;
      }
      return { enabled: false };
    }

    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return { enabled: false };
      }
      const config = parsed as NotifyConfigFile;
      return isConfigShapeValid(config) ? config : { enabled: false };
    } catch {
      return { enabled: false };
    }
  }
  return {};
}

function isLoopbackHostname(hostnameValue: string): boolean {
  const value = hostnameValue.toLowerCase().replace(/^\[|\]$/g, "");
  return value === "localhost" || value === "::1" || /^127(?:\.\d{1,3}){3}$/.test(value);
}

function applyEndpointPolicy(
  endpoint: string,
  requestedMode: "dynamic" | "static",
): { allowed: boolean; messageMode: "dynamic" | "static" } {
  let parsed: URL;
  try {
    parsed = new URL(endpoint);
  } catch {
    return { allowed: false, messageMode: "static" };
  }
  if (parsed.username || parsed.password) {
    return { allowed: false, messageMode: "static" };
  }

  const protocolAllowed = parsed.protocol === "http:" || parsed.protocol === "https:";
  if (!protocolAllowed) {
    return { allowed: false, messageMode: "static" };
  }
  if (isLoopbackHostname(parsed.hostname)) {
    return { allowed: true, messageMode: requestedMode };
  }
  if (parsed.protocol !== "https:" || !isTruthy(process.env.PI_NOTIFY_ALLOW_NONLOCAL)) {
    return { allowed: false, messageMode: "static" };
  }
  if (requestedMode === "dynamic" && !isTruthy(process.env.PI_NOTIFY_ALLOW_NONLOCAL_DYNAMIC)) {
    return { allowed: true, messageMode: "static" };
  }
  return { allowed: true, messageMode: requestedMode };
}

export async function getRuntimeConfig(): Promise<RuntimeConfig> {
  const file = await loadConfigFile();
  const endpoint = configString(process.env.PI_NOTIFY_ENDPOINT) || configString(file.endpoint) || DEFAULT_ENDPOINT;
  const modeValue = configString(process.env.PI_NOTIFY_MESSAGE_MODE) || file.messageMode;
  const requestedMode = modeValue === "static" ? "static" : "dynamic";
  const endpointPolicy = applyEndpointPolicy(endpoint, requestedMode);
  const timeoutValue = configString(process.env.PI_NOTIFY_TIMEOUT_MS) || (file.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  const timeoutRaw = Number(timeoutValue);
  const timeoutMs = Number.isFinite(timeoutRaw)
    ? Math.max(1000, Math.min(timeoutRaw, 15000))
    : DEFAULT_TIMEOUT_MS;

  const environmentOriginKind = configString(process.env.PI_NOTIFY_ORIGIN_KIND);
  const fileOriginKind = configString(file.originKind);
  const instanceKey =
    normalizeInstanceKey(process.env.PI_NOTIFY_INSTANCE_KEY) || normalizeInstanceKey(file.instanceKey);

  const xdgState = configString(process.env.XDG_STATE_HOME) || join(homedir(), ".local", "state");
  const defaultLeasePath = join(xdgState, "paseo-sender", "health.json");
  const leasePath =
    configString(process.env.PI_NOTIFY_PASEO_LEASE_PATH) ||
    configString(file.paseoLeasePath) ||
    defaultLeasePath;

  return {
    enabled: file.enabled !== false && !isTruthy(process.env.PI_NOTIFY_DISABLED) && endpointPolicy.allowed,
    endpoint,
    token: configString(process.env.PI_NOTIFY_TOKEN) || configString(file.token),
    timeoutMs,
    title: normalizeText(process.env.PI_NOTIFY_TITLE || file.title, "Pi", 80),
    bodyTemplate: normalizeText(
      process.env.PI_NOTIFY_BODY_TEMPLATE || file.bodyTemplate,
      "host: {host} | cwd: {cwdBase}",
      220,
    ),
    messageMode: endpointPolicy.messageMode,
    remoteHostAlias: normalizeText(process.env.PI_NOTIFY_REMOTE_ALIAS || file.remoteHostAlias, "", 64),
    piWebOriginConfigured:
      isExplicitPiWebOriginKind(environmentOriginKind) ||
      (isExplicitPiWebOriginKind(fileOriginKind) && isPiWebHostProcess()),
    instanceKey,
    paseoLeaseGateEnabled:
      isTruthy(process.env.PI_NOTIFY_PASEO_LEASE_GATE) || file.paseoLeaseGateEnabled === true,
    paseoLeasePath: resolve(leasePath),
  };
}

/** Pure paseo-sender readiness diagnostic; it never decides session ownership. */
export function isPaseoLeaseHealthy(
  lease: unknown,
  options: { staleMs?: number; now?: number } = {},
): boolean {
  const staleMs = options.staleMs ?? DEFAULT_PASEO_LEASE_STALE_MS;
  const now = options.now ?? Date.now();
  if (!lease || typeof lease !== "object") return false;
  const record = lease as {
    schemaVersion?: unknown;
    lastHealthyAt?: unknown;
    status?: unknown;
  };
  if (record.schemaVersion !== PASEO_LEASE_SCHEMA_VERSION) return false;
  if (typeof record.lastHealthyAt !== "number" || !Number.isFinite(record.lastHealthyAt)) return false;
  if (record.lastHealthyAt > now) return false;
  if (now - record.lastHealthyAt > staleMs) return false;
  if (record.status !== "healthy") return false;
  return true;
}

/**
 * Resolve the immutable notification owner for one Pi session runtime.
 * The launch marker is authoritative; sender health may affect delivery but must
 * never rebrand a Paseo-launched session as Pi/Pi Web.
 */
export function resolveSessionNotificationOwner(
  config: Pick<RuntimeConfig, "paseoLeaseGateEnabled">,
  options: { env?: NodeJS.ProcessEnv } = {},
): SessionNotificationOwner {
  const env = options.env ?? process.env;
  if (!config.paseoLeaseGateEnabled) return "pi";
  if (isTruthy(env.PI_NOTIFY_ALLOW_PASEO)) return "pi";
  if (!configString(env.PASEO_AGENT_ID)) return "pi";
  return "paseo";
}

/** Backwards-compatible predicate; the lease no longer participates in ownership. */
export async function shouldSuppressLegacyPiPopup(
  config: Pick<RuntimeConfig, "paseoLeaseGateEnabled" | "paseoLeasePath">,
  options: { env?: NodeJS.ProcessEnv } = {},
): Promise<boolean> {
  return resolveSessionNotificationOwner(config, options) === "paseo";
}

/**
 * Build additive route metadata for a notification.
 * TUI is always terminal. Pi-web exact fields require explicit config + valid instanceKey + raw session.
 * Missing/invalid Web metadata fails closed: originKind stays terminal and Web fields are omitted.
 */
export function buildNotifyRouteFields(
  mode: string | undefined,
  config: Pick<RuntimeConfig, "piWebOriginConfigured" | "instanceKey">,
  rawSessionId: string | undefined,
  notificationKind: NotificationKind,
): NotifyRouteFields {
  const base: NotifyRouteFields = {
    routeVersion: ROUTE_VERSION,
    notificationId: randomUUID(),
    notificationKind,
    originKind: "terminal",
  };

  // TUI is always terminal — never treat it as Pi Web even if Web config is present.
  if (mode === "tui") {
    return base;
  }

  if (
    !config.piWebOriginConfigured ||
    !config.instanceKey ||
    !isValidPiWebSessionId(rawSessionId)
  ) {
    return base;
  }

  try {
    const routingKey = computePiWebRoutingKey(config.instanceKey, rawSessionId);
    return {
      ...base,
      originKind: "pi-web",
      instanceKey: config.instanceKey,
      routingKey,
    };
  } catch {
    return base;
  }
}

function shouldSkipNotificationForThisProcess(): boolean {
  if (process.env.PI_SUBAGENT_CHILD === "1" || process.env.TRELLIS_SUBAGENT_CHILD === "1") {
    return true;
  }
  if (
    process.env.TRELLIS_CHANNEL &&
    process.env.TRELLIS_CHANNEL_AS &&
    process.env.PI_NOTIFY_ALLOW_TRELLIS_CHANNEL !== "1"
  ) {
    return true;
  }
  return false;
}

function normalizeTabTitlePart(value: unknown, fallback: string): string {
  const raw = typeof value === "string" ? value : "";
  const cleaned = raw
    .toWellFormed()
    .replace(OSC_SEQUENCE_PATTERN, " ")
    .replace(TERMINAL_STRING_PATTERN, " ")
    .replace(CSI_SEQUENCE_PATTERN, " ")
    .replace(ESC_SEQUENCE_PATTERN, " ")
    .replace(TITLE_CONTROL_PATTERN, " ")
    .replace(BIDI_CONTROL_PATTERN, " ")
    .replace(/\s+/gu, " ")
    .trim() || fallback;
  const characters = [...cleaned];
  if (characters.length <= 96) {
    return cleaned;
  }
  return `${characters.slice(0, 95).join("").trimEnd()}…`;
}

function getNotifyTarget(
  cwd: string,
  explicitSessionName?: string,
  sessionKey?: string,
): { cwdBase: string; tabTitle: string } {
  const cwdBase = normalizeTabTitlePart(basename(cwd) || cwd, "Pi");
  const safeName = explicitSessionName ? normalizeTabTitlePart(explicitSessionName, "") : "";
  const readableTitle = safeName
    ? `${PI_TERMINAL_TITLE} - ${safeName} - ${cwdBase}`
    : `${PI_TERMINAL_TITLE} - ${cwdBase}`;
  const identitySuffix = sessionKey ? ` · #${sessionKey}` : "";
  const readableBudget = MAX_CANONICAL_TITLE_BYTES - Buffer.byteLength(identitySuffix, "utf8");
  const tabTitle = `${truncateUtf8(readableTitle, readableBudget)}${identitySuffix}`;
  return { cwdBase, tabTitle };
}

function setTerminalTitle(title: string, mode?: string): void {
  if (mode !== "tui" || !process.stdout.isTTY) {
    return;
  }
  try {
    process.stdout.write(`\u001b]0;${title}\u0007`);
  } catch {
  }
}

async function notify(
  endpoint: string,
  token: string,
  payload: NotifyPayload,
  timeoutMs: number,
  lifecycleSignal: AbortSignal,
): Promise<void> {
  if (lifecycleSignal.aborted) {
    return;
  }
  const controller = new AbortController();
  const abortForLifecycle = () => controller.abort();
  lifecycleSignal.addEventListener("abort", abortForLifecycle, { once: true });
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Pi-Notify-Token": token,
      },
      body: JSON.stringify(payload),
      redirect: "error",
      signal: controller.signal,
    });
  } catch {
    // Notification and diagnostic failures must never break Pi.
  } finally {
    clearTimeout(timer);
    lifecycleSignal.removeEventListener("abort", abortForLifecycle);
  }
}

export default function remoteWindowsNotify(pi: ExtensionAPI): void {
  if (shouldSkipNotificationForThisProcess()) {
    return;
  }

  // Lifecycle state is owned by this factory invocation/runtime only.
  // Pi Web can load multiple independent runtimes (and resource-only factories)
  // in one Node process; they must not cancel or deactivate each other.
  const lifecycleController = new AbortController();
  const isAlive = () => !lifecycleController.signal.aborted;

  let currentSnapshot: ContextSnapshot | undefined;
  let sessionNotificationOwner: SessionNotificationOwner | undefined;

  // First observation wins for this session runtime; later health/config changes cannot rebrand it.
  const freezeSessionNotificationOwner = (config: RuntimeConfig): SessionNotificationOwner => {
    sessionNotificationOwner ??= resolveSessionNotificationOwner(config);
    return sessionNotificationOwner;
  };

  const promptUnsubscribe = pi.events.on(ASK_USER_PROMPT_EVENT, async (data) => {
    const snapshot = currentSnapshot ? { ...currentSnapshot } : undefined;
    if (!snapshot || !isAlive()) {
      return;
    }

    const config = await getRuntimeConfig();
    if (!isAlive() || !config.enabled || !config.token) {
      return;
    }
    if (freezeSessionNotificationOwner(config) === "paseo") {
      return;
    }

    let promptSummary = "";
    if (config.messageMode === "dynamic" && data && typeof data === "object") {
      const questions = (data as { questions?: unknown }).questions;
      const firstQuestion = Array.isArray(questions) && questions[0] && typeof questions[0] === "object"
        ? (questions[0] as { header?: unknown; question?: unknown })
        : undefined;
      promptSummary = configString(firstQuestion?.header) || configString(firstQuestion?.question);
    }

    const target = getNotifyTarget(snapshot.cwd, snapshot.explicitSessionName, snapshot.sessionKey);
    const body = config.messageMode === "dynamic"
      ? normalizeText(promptSummary ? `等待回答：${promptSummary}` : "Pi 正在等待你的回答", "Pi 正在等待你的回答", 220)
      : normalizeText(`Pi 正在等待你的回答 · ${renderBody(config.bodyTemplate, snapshot.cwd)}`, "Pi 正在等待你的回答", 220);
    const route = buildNotifyRouteFields(snapshot.mode, config, snapshot.rawSessionId, "ask-user");
    await notify(
      config.endpoint,
      config.token,
      {
        title: config.title,
        body,
        focusTarget: config.remoteHostAlias || undefined,
        cwdBase: target.cwdBase,
        tabTitle: target.tabTitle,
        sessionName: snapshot.displaySessionName,
        ...route,
      },
      config.timeoutMs,
      lifecycleController.signal,
    );
  });

  pi.on("session_start", async (_event, ctx) => {
    if (!isAlive()) {
      return;
    }
    const snapshot = readContextSnapshot(ctx);
    currentSnapshot = snapshot;
    setTerminalTitle(getNotifyTarget(snapshot.cwd, snapshot.explicitSessionName, snapshot.sessionKey).tabTitle, snapshot.mode);

    const config = await getRuntimeConfig();
    if (isAlive()) {
      freezeSessionNotificationOwner(config);
    }
  });

  pi.on("session_info_changed", (event, ctx) => {
    if (!isAlive()) {
      return;
    }
    const snapshot = readContextSnapshot(ctx);
    const explicitSessionName = normalizeTabTitlePart(event.name, "") || undefined;
    currentSnapshot = {
      ...snapshot,
      explicitSessionName,
      displaySessionName: explicitSessionName,
      sessionKey: snapshot.sessionKey ?? currentSnapshot?.sessionKey,
      rawSessionId: snapshot.rawSessionId ?? currentSnapshot?.rawSessionId,
    };
    setTerminalTitle(
      getNotifyTarget(currentSnapshot.cwd, currentSnapshot.explicitSessionName, currentSnapshot.sessionKey).tabTitle,
      currentSnapshot.mode,
    );
  });

  pi.on("session_shutdown", () => {
    // Idempotent: only cleans this runtime's listener and in-flight request.
    promptUnsubscribe();
    lifecycleController.abort();
  });

  pi.on("agent_end", async (event, ctx) => {
    if (shouldSkipNotificationForThisProcess() || !isAlive()) {
      return;
    }
    const config = await getRuntimeConfig();
    if (!isAlive() || !config.enabled || !config.token) {
      return;
    }
    if (freezeSessionNotificationOwner(config) === "paseo") {
      return;
    }

    const messages = Array.isArray((event as { messages?: AgentMessageLike[] }).messages)
      ? ((event as { messages: AgentMessageLike[] }).messages ?? [])
      : [];
    const liveSnapshot = readContextSnapshot(ctx, messages);
    const snapshot = {
      ...liveSnapshot,
      explicitSessionName: liveSnapshot.explicitSessionName ?? currentSnapshot?.explicitSessionName,
      displaySessionName: liveSnapshot.displaySessionName ?? currentSnapshot?.displaySessionName,
      sessionKey: liveSnapshot.sessionKey ?? currentSnapshot?.sessionKey,
      rawSessionId: liveSnapshot.rawSessionId ?? currentSnapshot?.rawSessionId,
    };
    const explicitSessionName = snapshot.explicitSessionName;
    const sessionName = snapshot.displaySessionName;
    const sessionKey = snapshot.sessionKey;
    const target = getNotifyTarget(snapshot.cwd, explicitSessionName, sessionKey);
    const payload = config.messageMode === "static"
      ? { title: config.title, body: renderBody(config.bodyTemplate, snapshot.cwd) }
      : buildDynamicNotification(messages, config, snapshot.cwd, sessionName);
    const route = buildNotifyRouteFields(snapshot.mode, config, snapshot.rawSessionId, "turn-complete");

    currentSnapshot = snapshot;
    setTerminalTitle(target.tabTitle, snapshot.mode);
    await notify(
      config.endpoint,
      config.token,
      {
        ...payload,
        focusTarget: config.remoteHostAlias || undefined,
        cwdBase: target.cwdBase,
        tabTitle: target.tabTitle,
        sessionName,
        ...route,
      },
      config.timeoutMs,
      lifecycleController.signal,
    );
  });
}
