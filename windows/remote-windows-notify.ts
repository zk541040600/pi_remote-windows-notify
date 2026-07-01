import { readFile } from "node:fs/promises";
import { hostname, homedir } from "node:os";
import { basename, join } from "node:path";
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

const DEFAULT_ENDPOINT = "http://127.0.0.1:23117/notify";
const DEFAULT_TIMEOUT_MS = 4000;
const DEFAULT_CONFIG_PATH = join(homedir(), ".pi", "agent", "remote-windows-notify.json");

let cachedConfigPromise: Promise<NotifyConfigFile> | null = null;

function isTruthy(value: string | undefined): boolean {
  return /^(1|true|yes|on)$/i.test((value ?? "").trim());
}

function normalizeText(value: string | undefined, fallback: string, maxLength: number): string {
  const collapsed = (value ?? "").replace(/\s+/g, " ").trim();
  const next = collapsed || fallback;
  return next.length > maxLength ? `${next.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…` : next;
}

function renderBody(template: string): string {
  const cwd = process.cwd();
  const cwdTail = basename(cwd) || cwd;
  return template
    .replace(/\{host\}/g, hostname())
    .replace(/\{cwd\}/g, cwd)
    .replace(/\{cwdBase\}/g, cwdTail);
}

function normalizeMode(value: string | undefined): "dynamic" | "static" {
  return value === "static" ? "static" : "dynamic";
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

function findLastTextForRole(messages: AgentMessageLike[], role: string): string {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
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

function collectToolInfo(messages: AgentMessageLike[]): { toolNames: string[]; hasError: boolean } {
  const seen = new Set<string>();
  const toolNames: string[] = [];
  let hasError = false;

  for (const message of messages) {
    if (message?.role !== "toolResult") {
      continue;
    }

    if (message.isError) {
      hasError = true;
    }

    const toolName = normalizeText(typeof message.toolName === "string" ? message.toolName : "", "", 32);
    if (!toolName || seen.has(toolName)) {
      continue;
    }

    seen.add(toolName);
    toolNames.push(toolName);
  }

  return { toolNames, hasError };
}

function buildDynamicNotification(messages: AgentMessageLike[], config: RuntimeConfig): { title: string; body: string } {
  const userPrompt = normalizeText(findLastTextForRole(messages, "user"), "", 72);
  const assistantText = normalizeText(findLastTextForRole(messages, "assistant"), "", 120);
  const { toolNames, hasError } = collectToolInfo(messages);

  const title = normalizeText(userPrompt || assistantText || config.title, "Pi", 72);
  const status = hasError ? "有报错，等你看" : toolNames.length > 0 ? "已完成，等你确认" : "已回复，等你输入";
  const bodyParts: string[] = [status];

  if (toolNames.length > 0) {
    bodyParts.push(`tools: ${toolNames.slice(0, 4).join(", ")}`);
  }

  if (assistantText && assistantText !== title) {
    bodyParts.push(assistantText);
  } else {
    bodyParts.push(renderBody(config.bodyTemplate));
  }

  return {
    title,
    body: normalizeText(bodyParts.join(" · "), renderBody(config.bodyTemplate), 220),
  };
}

async function loadConfigFile(): Promise<NotifyConfigFile> {
  if (!cachedConfigPromise) {
    const configPath = process.env.PI_NOTIFY_CONFIG || DEFAULT_CONFIG_PATH;
    cachedConfigPromise = readFile(configPath, "utf8")
      .then((raw) => JSON.parse(raw) as NotifyConfigFile)
      .catch(() => ({}));
  }
  return cachedConfigPromise;
}

async function getRuntimeConfig(): Promise<RuntimeConfig> {
  const file = await loadConfigFile();
  const enabled = !isTruthy(process.env.PI_NOTIFY_DISABLED) && file.enabled !== false;
  const timeoutRaw = Number(process.env.PI_NOTIFY_TIMEOUT_MS || file.timeoutMs || DEFAULT_TIMEOUT_MS);
  const timeoutMs = Number.isFinite(timeoutRaw) ? Math.max(1000, Math.min(timeoutRaw, 15000)) : DEFAULT_TIMEOUT_MS;

  return {
    enabled,
    endpoint: process.env.PI_NOTIFY_ENDPOINT || file.endpoint || DEFAULT_ENDPOINT,
    token: process.env.PI_NOTIFY_TOKEN || file.token || "",
    timeoutMs,
    title: normalizeText(process.env.PI_NOTIFY_TITLE || file.title, "Pi", 80),
    bodyTemplate: normalizeText(
      process.env.PI_NOTIFY_BODY_TEMPLATE || file.bodyTemplate,
      "host: {host} | cwd: {cwdBase}",
      220,
    ),
    messageMode: normalizeMode(process.env.PI_NOTIFY_MESSAGE_MODE || file.messageMode),
    remoteHostAlias: normalizeText(process.env.PI_NOTIFY_REMOTE_ALIAS || file.remoteHostAlias, "", 64),
  };
}

function shouldSkipNotificationForThisProcess(): boolean {
  return process.env.PI_SUBAGENT_CHILD === "1";
}

async function notify(
  endpoint: string,
  token: string,
  payload: { title: string; body: string; focusTarget?: string; cwdBase?: string },
  timeoutMs: number,
): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Pi-Notify-Token": token,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    if (!response.ok) {
      return;
    }
  } catch {
    // Notification failure must never break Pi.
  } finally {
    clearTimeout(timer);
  }
}

export default function remoteWindowsNotify(pi: ExtensionAPI) {
  pi.on("agent_end", async (event) => {
    if (shouldSkipNotificationForThisProcess()) {
      return;
    }

    const config = await getRuntimeConfig();
    if (!config.enabled || !config.token) {
      return;
    }

    const messages = Array.isArray((event as { messages?: AgentMessageLike[] }).messages)
      ? ((event as { messages: AgentMessageLike[] }).messages ?? [])
      : [];

    const payload =
      config.messageMode === "static"
        ? { title: config.title, body: renderBody(config.bodyTemplate) }
        : buildDynamicNotification(messages, config);

    await notify(
      config.endpoint,
      config.token,
      {
        ...payload,
        focusTarget: config.remoteHostAlias || undefined,
        cwdBase: basename(process.cwd()) || undefined,
      },
      config.timeoutMs,
    );
  });
}
