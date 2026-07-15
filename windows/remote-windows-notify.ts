import { createHash } from "node:crypto";
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
};

const DEFAULT_ENDPOINT = "http://127.0.0.1:23118/notify";
const DEFAULT_TIMEOUT_MS = 4000;
const DEFAULT_CONFIG_PATH = join(homedir(), ".pi", "agent", "remote-windows-notify.json");
const ASK_USER_PROMPT_EVENT = "rpiv:ask-user:prompt";
const PI_TERMINAL_TITLE = "π";
const MAX_CANONICAL_TITLE_BYTES = 144;
const SESSION_KEY_LENGTH = 12;
const OSC_SEQUENCE_PATTERN = /(?:\u001b\]|\u009d)[\s\S]*?(?:\u0007|\u001b\\|\u009c|$)/gu;
const TERMINAL_STRING_PATTERN = /(?:\u001b[P^_X]|\u0090|\u0098|\u009e|\u009f)[\s\S]*?(?:\u001b\\|\u009c|$)/gu;
const CSI_SEQUENCE_PATTERN = /(?:\u001b\[|\u009b)[0-?]*[ -/]*[@-~]/gu;
const ESC_SEQUENCE_PATTERN = /\u001b(?:[ -/]*[@-~])?/gu;
const TITLE_CONTROL_PATTERN = /[\u0000-\u001f\u007f-\u009f]+/gu;
const BIDI_CONTROL_PATTERN = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]+/gu;
const globalState = globalThis as {
  __piRemoteWindowsNotifyActiveToken?: symbol;
  __piRemoteWindowsNotifyLifecycleController?: AbortController;
  __piRemoteWindowsNotifyPromptUnsubscribe?: () => void;
};

function isTruthy(value: string | undefined): boolean {
  return /^(1|true|yes|on)$/i.test((value ?? "").trim());
}

function configString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
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

function readSessionKey(ctx: unknown): string | undefined {
  try {
    const manager = (ctx as { sessionManager?: { getSessionId?: () => unknown } })?.sessionManager;
    const sessionId = manager?.getSessionId?.();
    if (typeof sessionId !== "string" || !sessionId.trim()) {
      return undefined;
    }
    return createHash("sha256").update(sessionId).digest("hex").slice(0, SESSION_KEY_LENGTH);
  } catch {
    return undefined;
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
    const manager = (ctx as { sessionManager?: { getSessionName?: () => unknown } })?.sessionManager;
    explicitSessionName = normalizeTabTitlePart(manager?.getSessionName?.(), "") || undefined;
  } catch {
  }

  const displaySessionName =
    explicitSessionName || normalizeText(findTextForRole(messages, "user", false), "", 96) || undefined;
  return { cwd, mode, explicitSessionName, displaySessionName, sessionKey: readSessionKey(ctx) };
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
): { title: string; body: string } {
  const userPrompt = normalizeText(findTextForRole(messages, "user", true), "", 72);
  const assistantText = normalizeText(findTextForRole(messages, "assistant", true), "", 120);
  const { toolNames, hasToolError, hasTrailingToolError } = collectToolInfo(messages);
  const title = normalizeText(userPrompt || assistantText || config.title, "Pi", 72);
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
  };
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
  payload: { title: string; body: string; focusTarget?: string; cwdBase?: string; tabTitle?: string; sessionName?: string },
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

  const activeToken = Symbol("pi-remote-windows-notify");
  const lifecycleController = new AbortController();
  globalState.__piRemoteWindowsNotifyPromptUnsubscribe?.();
  globalState.__piRemoteWindowsNotifyLifecycleController?.abort();
  globalState.__piRemoteWindowsNotifyActiveToken = activeToken;
  globalState.__piRemoteWindowsNotifyLifecycleController = lifecycleController;
  const isActiveExtension = () => globalState.__piRemoteWindowsNotifyActiveToken === activeToken;

  let currentSnapshot: ContextSnapshot | undefined;

  const promptUnsubscribe = pi.events.on(ASK_USER_PROMPT_EVENT, async (data) => {
    const snapshot = currentSnapshot ? { ...currentSnapshot } : undefined;
    if (!snapshot || !isActiveExtension()) {
      return;
    }

    const config = await getRuntimeConfig();
    if (!isActiveExtension() || lifecycleController.signal.aborted || !config.enabled || !config.token) {
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
      },
      config.timeoutMs,
      lifecycleController.signal,
    );
  });
  globalState.__piRemoteWindowsNotifyPromptUnsubscribe = promptUnsubscribe;

  pi.on("session_start", (_event, ctx) => {
    if (!isActiveExtension()) {
      return;
    }
    const snapshot = readContextSnapshot(ctx);
    currentSnapshot = snapshot;
    setTerminalTitle(getNotifyTarget(snapshot.cwd, snapshot.explicitSessionName, snapshot.sessionKey).tabTitle, snapshot.mode);
  });

  pi.on("session_info_changed", (event, ctx) => {
    if (!isActiveExtension()) {
      return;
    }
    const snapshot = readContextSnapshot(ctx);
    const explicitSessionName = normalizeTabTitlePart(event.name, "") || undefined;
    currentSnapshot = {
      ...snapshot,
      explicitSessionName,
      displaySessionName: explicitSessionName,
      sessionKey: snapshot.sessionKey ?? currentSnapshot?.sessionKey,
    };
    setTerminalTitle(
      getNotifyTarget(currentSnapshot.cwd, currentSnapshot.explicitSessionName, currentSnapshot.sessionKey).tabTitle,
      currentSnapshot.mode,
    );
  });

  pi.on("session_shutdown", () => {
    promptUnsubscribe();
    lifecycleController.abort();
    if (isActiveExtension()) {
      delete globalState.__piRemoteWindowsNotifyActiveToken;
      delete globalState.__piRemoteWindowsNotifyLifecycleController;
      if (globalState.__piRemoteWindowsNotifyPromptUnsubscribe === promptUnsubscribe) {
        delete globalState.__piRemoteWindowsNotifyPromptUnsubscribe;
      }
    }
  });

  pi.on("agent_end", async (event, ctx) => {
    if (shouldSkipNotificationForThisProcess() || !isActiveExtension()) {
      return;
    }
    const config = await getRuntimeConfig();
    if (!isActiveExtension() || lifecycleController.signal.aborted || !config.enabled || !config.token) {
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
    };
    const explicitSessionName = snapshot.explicitSessionName;
    const sessionName = snapshot.displaySessionName;
    const sessionKey = snapshot.sessionKey;
    const target = getNotifyTarget(snapshot.cwd, explicitSessionName, sessionKey);
    const payload = config.messageMode === "static"
      ? { title: config.title, body: renderBody(config.bodyTemplate, snapshot.cwd) }
      : buildDynamicNotification(messages, config, snapshot.cwd);

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
      },
      config.timeoutMs,
      lifecycleController.signal,
    );
  });
}
