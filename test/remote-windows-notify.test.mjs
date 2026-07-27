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
const ASK_USER_PROMPT_EVENT = "rpiv:ask-user:prompt";

function restoreProcessState() {
  for (const key of ENV_KEYS) {
    const value = savedEnv.get(key);
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
  globalThis.__piRemoteWindowsNotifyPromptUnsubscribe?.();
  delete globalThis.__piRemoteWindowsNotifyActiveToken;
  delete globalThis.__piRemoteWindowsNotifyLifecycleController;
  delete globalThis.__piRemoteWindowsNotifyPromptUnsubscribe;
  globalThis.fetch = originalFetch;
}

function clearNotifyEnvironment() {
  for (const key of ENV_KEYS) {
    delete process.env[key];
  }
  globalThis.__piRemoteWindowsNotifyPromptUnsubscribe?.();
  delete globalThis.__piRemoteWindowsNotifyActiveToken;
  delete globalThis.__piRemoteWindowsNotifyLifecycleController;
  delete globalThis.__piRemoteWindowsNotifyPromptUnsubscribe;
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
  const eventHandlers = new Map();
  return {
    pi: {
      on(event, handler) {
        const current = handlers.get(event) ?? [];
        current.push(handler);
        handlers.set(event, current);
      },
      events: {
        emit(channel, data) {
          for (const handler of eventHandlers.get(channel) ?? []) {
            void handler(data);
          }
        },
        on(channel, handler) {
          const current = eventHandlers.get(channel) ?? new Set();
          current.add(handler);
          eventHandlers.set(channel, current);
          return () => current.delete(handler);
        },
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
    countEvent(channel) {
      return eventHandlers.get(channel)?.size ?? 0;
    },
    async emitEvent(channel, data) {
      await Promise.all([...(eventHandlers.get(channel) ?? [])].map((handler) => handler(data)));
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

test("ask-user prompt sends one targeted notification before turn end", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "dynamic",
    remoteHostAlias: "my",
  });
  const requests = [];
  globalThis.fetch = async (_endpoint, options) => {
    requests.push(JSON.parse(options.body));
    return { ok: true };
  };

  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  const sessionId = "prompt-session-id";
  const context = createContext({
    sessionManager: {
      getSessionName: () => "prompt-session",
      getSessionId: () => sessionId,
    },
  });
  await runtime.emit("session_start", { type: "session_start" }, context);
  const longHeader = `进程\n模型${"😀".repeat(230)}`;
  await runtime.emitEvent(ASK_USER_PROMPT_EVENT, {
    questions: [{ header: longHeader, question: "选择进程模型", options: [] }],
  });
  await runtime.emitEvent("unrelated:custom-ui", {});

  const expectedKey = createHash("sha256").update(sessionId).digest("hex").slice(0, 12);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].focusTarget, "my");
  assert.equal(requests[0].cwdBase, "actual-project");
  assert.equal(requests[0].sessionName, "prompt-session");
  assert.match(requests[0].tabTitle, new RegExp(` · #${expectedKey}$`));
  assert.match(requests[0].body, /^等待回答：进程 模型/);
  assert.ok([...requests[0].body].length <= 220);
  assert.doesNotMatch(requests[0].body, /[\u0000-\u001f\u007f]/);

  await runtime.emit("agent_end", { type: "agent_end", messages: [] }, context);
  assert.equal(requests.length, 2, "the later turn-complete notification remains a separate state");

  // Network failures from waiting notifications must not surface to the prompt event path.
  let failureCount = 0;
  globalThis.fetch = async () => {
    failureCount += 1;
    throw new Error("listener unavailable");
  };
  await runtime.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [{ header: "retry" }] });
  assert.equal(failureCount, 1);
});

test("static ask-user notification does not expose question content", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "static",
    bodyTemplate: "cwd={cwdBase}",
  });
  let payload;
  globalThis.fetch = async (_endpoint, options) => {
    payload = JSON.parse(options.body);
    return { ok: true };
  };

  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  await runtime.emit("session_start", { type: "session_start" }, createContext());
  await runtime.emitEvent(ASK_USER_PROMPT_EVENT, {
    questions: [{ header: "secret-header", question: "secret-question", options: [{ label: "secret-option" }] }],
  });

  assert.equal(payload.body, "Pi 正在等待你的回答 · cwd=actual-project");
  assert.doesNotMatch(JSON.stringify(payload), /secret-(?:header|question|option)/);
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

test("independent runtimes notify with their own session and cwd identity", async (t) => {
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

  const runtimeA = createFakePi();
  const runtimeB = createFakePi();
  remoteWindowsNotify(runtimeA.pi);
  remoteWindowsNotify(runtimeB.pi);

  const sessionA = "session-runtime-a";
  const sessionB = "session-runtime-b";
  const keyA = createHash("sha256").update(sessionA).digest("hex").slice(0, 12);
  const keyB = createHash("sha256").update(sessionB).digest("hex").slice(0, 12);
  const contextA = createContext({
    cwd: "/workspace/project-a",
    sessionManager: {
      getSessionName: () => "alpha",
      getSessionId: () => sessionA,
    },
  });
  const contextB = createContext({
    cwd: "/workspace/project-b",
    sessionManager: {
      getSessionName: () => "beta",
      getSessionId: () => sessionB,
    },
  });

  await runtimeA.emit("session_start", { type: "session_start" }, contextA);
  await runtimeB.emit("session_start", { type: "session_start" }, contextB);
  await runtimeA.emit("agent_end", { type: "agent_end", messages: [] }, contextA);
  await runtimeB.emit("agent_end", { type: "agent_end", messages: [] }, contextB);

  assert.equal(requests.length, 2);
  assert.equal(requests[0].cwdBase, "project-a");
  assert.equal(requests[1].cwdBase, "project-b");
  assert.match(requests[0].tabTitle, new RegExp(` · #${keyA}$`));
  assert.match(requests[1].tabTitle, new RegExp(` · #${keyB}$`));
  assert.notEqual(requests[0].tabTitle, requests[1].tabTitle);
});

test("resource-only factory load does not deactivate an active chat runtime", async (t) => {
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

  const chat = createFakePi();
  remoteWindowsNotify(chat.pi);
  await chat.emit("session_start", { type: "session_start" }, createContext({ cwd: "/workspace/chat" }));
  await chat.emit("agent_end", { type: "agent_end", messages: [] }, createContext({ cwd: "/workspace/chat" }));
  assert.equal(requestCount, 1);

  // Resource discovery loads the extension factory without a session_start.
  const resourceOnly = createFakePi();
  remoteWindowsNotify(resourceOnly.pi);
  assert.equal(resourceOnly.count("agent_end"), 1);
  assert.equal(resourceOnly.countEvent(ASK_USER_PROMPT_EVENT), 1);

  await chat.emit("agent_end", { type: "agent_end", messages: [] }, createContext({ cwd: "/workspace/chat" }));
  assert.equal(requestCount, 2, "chat runtime must keep notifying after a resource-only factory load");
});

test("runtime shutdown is idempotent and only cleans up its own lifecycle", async (t) => {
  writeConfig(t, {
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-token",
    messageMode: "dynamic",
  });
  const requests = [];
  globalThis.fetch = async (_endpoint, options) => {
    requests.push(JSON.parse(options.body));
    return { ok: true };
  };

  const runtimeA = createFakePi();
  const runtimeB = createFakePi();
  remoteWindowsNotify(runtimeA.pi);
  remoteWindowsNotify(runtimeB.pi);

  const contextA = createContext({ cwd: "/workspace/a" });
  const contextB = createContext({ cwd: "/workspace/b" });
  await runtimeA.emit("session_start", { type: "session_start" }, contextA);
  await runtimeB.emit("session_start", { type: "session_start" }, contextB);

  await runtimeA.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [] });
  await runtimeB.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [] });
  assert.equal(requests.length, 2, "both live runtimes must receive their own prompt event");
  assert.deepEqual(requests.map((request) => request.cwdBase), ["a", "b"]);

  await runtimeA.emit("session_shutdown", { type: "session_shutdown" }, contextA);
  await runtimeA.emit("session_shutdown", { type: "session_shutdown" }, contextA);
  assert.equal(runtimeA.countEvent(ASK_USER_PROMPT_EVENT), 0);
  assert.equal(runtimeB.countEvent(ASK_USER_PROMPT_EVENT), 1);

  await runtimeA.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [] });
  await runtimeB.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [] });
  assert.equal(requests.length, 3);
  assert.equal(requests[2].cwdBase, "b");

  await runtimeA.emit("agent_end", { type: "agent_end", messages: [] }, contextA);
  await runtimeB.emit("agent_end", { type: "agent_end", messages: [] }, contextB);
  assert.equal(requests.length, 4);
  assert.equal(requests[3].cwdBase, "b");

  // Host reload contract: after shutdown, a replacement runtime on a new bus can notify again.
  const reloaded = createFakePi();
  remoteWindowsNotify(reloaded.pi);
  await reloaded.emit("session_start", { type: "session_start" }, createContext({ cwd: "/workspace/reloaded" }));
  await reloaded.emitEvent(ASK_USER_PROMPT_EVENT, { questions: [] });
  assert.equal(requests.length, 5);
  assert.equal(requests[4].cwdBase, "reloaded");
  await reloaded.emit("session_shutdown", { type: "session_shutdown" }, createContext({ cwd: "/workspace/reloaded" }));
  assert.equal(reloaded.countEvent(ASK_USER_PROMPT_EVENT), 0);
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

test("loading a second runtime does not abort the first runtime request", async (t) => {
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
    if (!firstSignal) {
      firstSignal = options.signal;
      started();
      return new Promise((_resolve, reject) => {
        options.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      });
    }
    return { ok: true };
  };
  const first = createFakePi();
  remoteWindowsNotify(first.pi);
  const pending = first.emit("agent_end", { type: "agent_end", messages: [] }, createContext());
  await fetchStarted;

  const second = createFakePi();
  remoteWindowsNotify(second.pi);
  assert.equal(firstSignal.aborted, false, "independent runtime load must not abort in-flight requests");

  await second.emit("session_shutdown", { type: "session_shutdown" }, createContext());
  assert.equal(firstSignal.aborted, false, "shutdown of another runtime must not abort this request");

  await first.emit("session_shutdown", { type: "session_shutdown" }, createContext());
  await pending;
  assert.equal(firstSignal.aborted, true, "only the owning runtime shutdown aborts its request");
});

test("worker processes do not register notification handlers", () => {
  process.env.PI_SUBAGENT_CHILD = "1";
  const runtime = createFakePi();
  remoteWindowsNotify(runtime.pi);
  assert.equal(runtime.count("agent_end"), 0);
  assert.equal(runtime.count("session_shutdown"), 0);
  assert.equal(runtime.countEvent(ASK_USER_PROMPT_EVENT), 0);
});
