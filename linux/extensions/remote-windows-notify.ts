import { readFile } from "node:fs/promises";
import { hostname, homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type NotifyConfigFile = {
  enabled?: boolean;
  endpoint?: string;
  token?: string;
  timeoutMs?: number;
  title?: string;
  bodyTemplate?: string;
};

type RuntimeConfig = {
  enabled: boolean;
  endpoint: string;
  token: string;
  timeoutMs: number;
  title: string;
  bodyTemplate: string;
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
  return next.length > maxLength ? next.slice(0, maxLength) : next;
}

function renderBody(template: string): string {
  return template.replace(/\{host\}/g, hostname()).replace(/\{cwd\}/g, process.cwd());
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
      "Remote Pi on {host} is ready for input",
      220,
    ),
  };
}

async function notify(endpoint: string, token: string, title: string, body: string, timeoutMs: number): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Pi-Notify-Token": token,
      },
      body: JSON.stringify({ title, body }),
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
  pi.on("agent_end", async () => {
    const config = await getRuntimeConfig();
    if (!config.enabled || !config.token) {
      return;
    }

    await notify(
      config.endpoint,
      config.token,
      config.title,
      renderBody(config.bodyTemplate),
      config.timeoutMs,
    );
  });
}
