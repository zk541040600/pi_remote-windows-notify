import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import remoteWindowsNotify, {
  getRuntimeConfig,
} from "../linux/extensions/remote-windows-notify.ts";

const ENV_KEYS = [
  "PI_NOTIFY_ALLOW_NONLOCAL",
  "PI_NOTIFY_ALLOW_NONLOCAL_DYNAMIC",
  "PI_NOTIFY_ALLOW_TRELLIS_CHANNEL",
  "PI_NOTIFY_BODY_TEMPLATE",
  "PI_NOTIFY_CONFIG",
  "PI_NOTIFY_DISABLED",
  "PI_NOTIFY_ENDPOINT",
  "PI_NOTIFY_MESSAGE_MODE",
  "PI_NOTIFY_REMOTE_ALIAS",
  "PI_NOTIFY_TIMEOUT_MS",
  "PI_NOTIFY_TITLE",
  "PI_NOTIFY_TOKEN",
  "PI_SUBAGENT_CHILD",
  "TRELLIS_CHANNEL",
  "TRELLIS_CHANNEL_AS",
  "TRELLIS_SUBAGENT_CHILD",
];
const savedEnv = new Map(ENV_KEYS.map((key) => [key, process.env[key]]));
const originalFetch = globalThis.fetch;

function restoreProcessState() {
  for (const key of ENV_KEYS) {
    const value = savedEnv.get(key);
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
  delete globalThis.__piRemoteWindowsNotifyActiveToken;
  delete globalThis.__piRemoteWindowsNotifyLifecycleController;
  globalThis.fetch = originalFetch;
}

function clearNotifyEnvironment() {
  for (const key of ENV_KEYS) {
    delete process.env[key];
  }
  delete globalThis.__piRemoteWindowsNotifyActiveToken;
  delete globalThis.__piRemoteWindowsNotifyLifecycleController;
  globalThis.fetch = originalFetch;
}

function writeConfig(t, value, raw = false) {
  const dir = mkdtempSync(join(tmpdir(), "pi-remote-windows-notify-test-"));
  const path = join(dir, "config.json");
  writeFileSync(path, raw ? value : JSON.stringify(value), "utf8");
  chmodSync(path, 0o600);
  process.env.PI_NOTIFY_CONFIG = path;
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return path;
}

function createFakePi() {
  const handlers = new Map();
  return {
    pi: {
      on(event, handler) {
        const current = handlers.get(event) ?? [];
        current.push(handler);
        handlers.set(event, current);
      },
    },
    count(event) {
      return handlers.get(event)?.length ?? 0;
    },
    async emit(event, payload = { type: event }, context = {}) {
      for (const handler of handlers.get(event) ?? []) {
        await handler(payload, context);
      }
    },
  };
}

function createContext(overrides = {}) {
  return {
    cwd: "/workspace/actual-project",
    mode: "json",
    sessionManager: {
      getSessionName: () => undefined,
    },
    ...overrides,
  };
}

beforeEach(clearNotifyEnvironment);
afterEach(restoreProcessState);

test("runtime config enforces endpoint and dynamic-content policy", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "dynamic",
  });
  let config = await getRuntimeConfig();
  assert.equal(config.enabled, true);
  assert.equal(config.messageMode, "dynamic");

  writeConfig(t, {
    endpoint: "http://example.com/notify",
    token: "test-token",
    messageMode: "static",
  });
  process.env.PI_NOTIFY_ALLOW_NONLOCAL = "1";
  config = await getRuntimeConfig();
  assert.equal(config.enabled, false, "plaintext non-loopback endpoints must stay disabled");

  writeConfig(t, {
    endpoint: "https://example.com/notify",
    token: "test-token",
    messageMode: "dynamic",
  });
  config = await getRuntimeConfig();
  assert.equal(config.enabled, true);
  assert.equal(config.messageMode, "static", "nonlocal dynamic content needs a second opt-in");

  process.env.PI_NOTIFY_ALLOW_NONLOCAL_DYNAMIC = "1";
  config = await getRuntimeConfig();
  assert.equal(config.messageMode, "dynamic");

  writeConfig(t, {
    endpoint: "http://user:password@127.0.0.1:23118/notify",
    token: "test-token",
  });
  config = await getRuntimeConfig();
  assert.equal(config.enabled, false, "endpoint credentials must not be accepted");
});

test("runtime config fails closed for explicit missing, malformed, or invalid config", async (t) => {
  const missingDir = mkdtempSync(join(tmpdir(), "pi-notify-missing-config-"));
  t.after(() => rmSync(missingDir, { recursive: true, force: true }));
  process.env.PI_NOTIFY_CONFIG = join(missingDir, "missing.json");
  process.env.PI_NOTIFY_TOKEN = "env-token";
  let config = await getRuntimeConfig();
  assert.equal(config.enabled, false);

  writeConfig(t, "{bad-json", true);
  config = await getRuntimeConfig();
  assert.equal(config.enabled, false);

  writeConfig(t, { endpoint: 23118, token: "test-token" });
  config = await getRuntimeConfig();
  assert.equal(config.enabled, false);
});

test("runtime config clamps timeouts and accepts loopback IPv6", async (t) => {
  writeConfig(t, {
    endpoint: "http://[::1]:23118/notify",
    token: "test-token",
    timeoutMs: 999999,
  });
  let config = await getRuntimeConfig();
  assert.equal(config.enabled, true);
  assert.equal(config.timeoutMs, 15000);

  process.env.PI_NOTIFY_TIMEOUT_MS = "1";
  config = await getRuntimeConfig();
  assert.equal(config.timeoutMs, 1000);
});

test("environment-only configuration works when no config file exists", async () => {
  process.env.PI_NOTIFY_ENDPOINT = "http://127.0.0.1:23118/notify";
  process.env.PI_NOTIFY_TOKEN = "env-token";
  const config = await getRuntimeConfig();
  assert.equal(config.enabled, true);
  assert.equal(config.token, "env-token");
});

test("agent_end uses live context, sanitizes text, and sends one bounded payload", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "dynamic",
    remoteHostAlias: "my",
  });
  const requests = [];
  globalThis.fetch = async (endpoint, options) => {
    requests.push({ endpoint, options, payload: JSON.parse(options.body) });
    return { ok: true };
  };

  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  const throwingContext = createContext({
    sessionManager: {
      getSessionName() {
        throw new Error("stale session");
      },
    },
  });
  await runtime.emit("session_start", { type: "session_start", reason: "startup" }, throwingContext);
  await runtime.emit(
    "agent_end",
    {
      type: "agent_end",
      messages: [
        { role: "user", content: "Review\u001b]0;bad\u0007 plugin" },
        { role: "toolResult", toolName: "shell_command", isError: false, content: "ok" },
        { role: "assistant", content: "😀".repeat(300) },
      ],
    },
    throwingContext,
  );

  assert.equal(requests.length, 1);
  assert.equal(requests[0].endpoint, "http://127.0.0.1:23118/notify");
  assert.equal(requests[0].options.headers["X-Pi-Notify-Token"], "test-token");
  assert.equal(requests[0].options.redirect, "error");
  assert.equal(requests[0].payload.cwdBase, "actual-project");
  assert.equal(requests[0].payload.focusTarget, "my");
  assert.match(requests[0].payload.tabTitle, /^π - actual-project$/);
  assert.doesNotMatch(requests[0].payload.sessionName, /[\u0000-\u001f\u007f]/);
  assert.ok([...requests[0].payload.body].length <= 220);
  assert.doesNotMatch(requests[0].payload.body, /[\uD800-\uDFFF](?![\uDC00-\uDFFF])/u);
});

test("session identity makes same-cwd targets stable, distinct, and non-reversible", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
  });
  const requests = [];
  globalThis.fetch = async (_endpoint, options) => {
    requests.push(JSON.parse(options.body));
    return { ok: true };
  };

  const originalIsTty = Object.getOwnPropertyDescriptor(process.stdout, "isTTY");
  const originalWrite = process.stdout.write;
  const terminalWrites = [];
  Object.defineProperty(process.stdout, "isTTY", { value: true, configurable: true });
  process.stdout.write = (chunk) => {
    terminalWrites.push(String(chunk));
    return true;
  };
  t.after(() => {
    process.stdout.write = originalWrite;
    if (originalIsTty) {
      Object.defineProperty(process.stdout, "isTTY", originalIsTty);
    } else {
      delete process.stdout.isTTY;
    }
  });

  const sessionId = "private-session-alpha";
  const expectedKey = createHash("sha256").update(sessionId).digest("hex").slice(0, 12);
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  const context = createContext({
    mode: "tui",
    sessionManager: {
      getSessionName: () => "shared-name",
      getSessionId: () => sessionId,
    },
  });
  await runtime.emit("session_start", { type: "session_start" }, context);
  await runtime.emit("session_info_changed", { type: "session_info_changed", name: "shared-name" }, context);
  await runtime.emit("agent_end", { type: "agent_end", messages: [] }, context);

  const expectedTitle = `π - shared-name - actual-project · #${expectedKey}`;
  assert.equal(requests[0].tabTitle, expectedTitle);
  const titleWrites = terminalWrites.filter((write) => write.startsWith("\u001b]0;"));
  assert.equal(titleWrites.length, 3);
  assert.ok(titleWrites.every((write) => write === `\u001b]0;${expectedTitle}\u0007`));
  assert.doesNotMatch(JSON.stringify(requests[0]), new RegExp(sessionId));

  await runtime.emit("session_shutdown", { type: "session_shutdown" }, context);
  const secondSessionId = "private-session-beta";
  const secondRuntime = createFakePi();
  remoteWindowsNotify(secondRuntime.pi);
  const secondContext = createContext({
    mode: "tui",
    sessionManager: {
      getSessionName: () => "shared-name",
      getSessionId: () => secondSessionId,
    },
  });
  await secondRuntime.emit("agent_end", { type: "agent_end", messages: [] }, secondContext);
  assert.notEqual(requests[1].tabTitle, expectedTitle);
  assert.match(requests[1].tabTitle, /^π - shared-name - actual-project · #[0-9a-f]{12}$/);
  assert.doesNotMatch(JSON.stringify(requests[1]), new RegExp(secondSessionId));
});

test("canonical target keeps its session suffix within the UTF-8 byte cap", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
  });
  let payload;
  globalThis.fetch = async (_endpoint, options) => {
    payload = JSON.parse(options.body);
    return { ok: true };
  };

  const sessionId = "long-unicode-session";
  const expectedKey = createHash("sha256").update(sessionId).digest("hex").slice(0, 12);
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  await runtime.emit(
    "agent_end",
    { type: "agent_end", messages: [] },
    createContext({
      cwd: `/workspace/${"界".repeat(100)}`,
      sessionManager: {
        getSessionName: () => "会话".repeat(100),
        getSessionId: () => sessionId,
      },
    }),
  );

  assert.ok(Buffer.byteLength(payload.tabTitle, "utf8") <= 144);
  assert.match(payload.tabTitle, new RegExp(` · #${expectedKey}$`));
  assert.equal(payload.tabTitle.isWellFormed(), true);
});

test("static body expansion is bounded and uses context cwd", async (t) => {
  writeConfig(t, {
    endpoint: "http://localhost:23118/notify",
    token: "test-token",
    messageMode: "static",
    bodyTemplate: "cwd={cwd}",
  });
  let payload;
  globalThis.fetch = async (_endpoint, options) => {
    payload = JSON.parse(options.body);
    return { ok: true };
  };
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  const longCwd = `/workspace/${"x".repeat(400)}`;
  await runtime.emit("agent_end", { type: "agent_end", messages: [] }, createContext({ cwd: longCwd }));
  assert.ok([...payload.body].length <= 220);
  assert.equal(payload.cwdBase, `${"x".repeat(95)}…`);
});

test("only the latest loaded instance can notify", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
  });
  let requestCount = 0;
  globalThis.fetch = async () => {
    requestCount += 1;
    return { ok: true };
  };
  const first = createFakePi();
  const second = createFakePi();
  remoteWindowsNotify(first.pi);
  remoteWindowsNotify(second.pi);

  await first.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  await second.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  assert.equal(requestCount, 1);

  await first.emit("session_shutdown", { type: "session_shutdown" }, createContext());
  await second.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  assert.equal(requestCount, 2, "stale shutdown must not deactivate the latest instance");
});

test("session shutdown aborts an in-flight request without surfacing an error", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
  });
  let started;
  const fetchStarted = new Promise((resolve) => {
    started = resolve;
  });
  let observedSignal;
  globalThis.fetch = async (_endpoint, options) => {
    observedSignal = options.signal;
    started();
    return new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
    });
  };
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  const pending = runtime.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  await fetchStarted;
  await runtime.emit("session_shutdown", { type: "session_shutdown" }, createContext());
  await pending;
  assert.equal(observedSignal.aborted, true);
});

test("loading a replacement instance aborts the previous instance request", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
  });
  let started;
  const fetchStarted = new Promise((resolve) => {
    started = resolve;
  });
  let firstSignal;
  globalThis.fetch = async (_endpoint, options) => {
    firstSignal = options.signal;
    started();
    return new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(new Error("reloaded")), { once: true });
    });
  };
  const first = createFakePi();
  remoteWindowsNotify(first.pi);
  const pending = first.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  await fetchStarted;

  const replacement = createFakePi();
  remoteWindowsNotify(replacement.pi);
  await pending;
  assert.equal(firstSignal.aborted, true);
});

test("worker processes do not register notification handlers", () => {
  process.env.PI_SUBAGENT_CHILD = "1";
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  assert.equal(runtime.count("agent_end"), 0);
  assert.equal(runtime.count("session_shutdown"), 0);
});
