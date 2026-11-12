import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import remoteWindowsNotify from "../linux/extensions/remote-windows-notify.ts";

const ASK_USER_PROMPT_EVENT = "rpiv:ask-user:prompt";
const INSTANCE_KEY = "11111111-2222-3333-4444-555555555555";
const ENV_KEYS = [
  "PI_WEB_NO_OPEN", "PI_SUBAGENT_CHILD", "TRELLIS_SUBAGENT_CHILD",
  "TRELLIS_CHANNEL", "TRELLIS_CHANNEL_AS", "PI_NOTIFY_ALLOW_TRELLIS_CHANNEL",
  "PI_NOTIFY_CONFIG", "PI_NOTIFY_DISABLED", "PI_NOTIFY_ENDPOINT", "PI_NOTIFY_TOKEN",
  "PI_NOTIFY_ORIGIN_KIND", "PI_NOTIFY_INSTANCE_KEY", "PI_NOTIFY_MESSAGE_MODE",
  "PI_NOTIFY_PASEO_LEASE_GATE", "PI_NOTIFY_ALLOW_PASEO", "PASEO_AGENT_ID",
];
const savedEnv = new Map(ENV_KEYS.map((key) => [key, process.env[key]]));
const originalFetch = globalThis.fetch;
let configDir;
let requests;

beforeEach(() => {
  for (const key of ENV_KEYS) delete process.env[key];
  configDir = mkdtempSync(join(tmpdir(), "pi-notify-subagents-"));
  process.env.PI_NOTIFY_CONFIG = join(configDir, "config.json");
  writeFileSync(process.env.PI_NOTIFY_CONFIG, JSON.stringify({
    endpoint: "http://127.0.0.1:23118/notify",
    token: "test-only-token",
    messageMode: "static",
    originKind: "pi-web",
    instanceKey: INSTANCE_KEY,
    paseoLeaseGateEnabled: false,
  }), { mode: 0o600 });
  process.env.PI_WEB_NO_OPEN = "1";
  requests = [];
  globalThis.fetch = async (_endpoint, options) => {
    requests.push(JSON.parse(options.body));
    return { ok: true };
  };
});

afterEach(() => {
  for (const [key, value] of savedEnv) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  globalThis.fetch = originalFetch;
  rmSync(configDir, { recursive: true, force: true });
});

function createRuntime(mode, { name = "ordinary-session", persisted = false, parent = false } = {}) {
  const handlers = new Map();
  const prompts = new Set();
  const context = {
    cwd: "/workspace/project",
    mode,
    hasUI: mode === "rpc" || mode === "tui",
    sessionManager: {
      getSessionId: () => name,
      getSessionName: () => name,
      getSessionFile: () => persisted ? `/sessions/${name}.jsonl` : undefined,
      getHeader: () => ({ parentSession: parent ? "/sessions/parent.jsonl" : undefined }),
    },
  };
  remoteWindowsNotify({
    on(event, handler) {
      handlers.set(event, handler);
    },
    events: {
      on(channel, handler) {
        assert.equal(channel, ASK_USER_PROMPT_EVENT);
        prompts.add(handler);
        return () => prompts.delete(handler);
      },
    },
  });
  return {
    context,
    async emit(event, payload = { type: event }) {
      await handlers.get(event)?.(payload, context);
    },
    async ask() {
      await Promise.all([...prompts].map((handler) => handler({ questions: [{ header: "Test" }] })));
    },
    handlerCount: () => handlers.size,
    promptCount: () => prompts.size,
  };
}

for (const mode of ["print", "json"]) {
  for (const persisted of [false, true]) {
    test(`headless Web ${mode} runtime suppresses asks and completion (persisted=${persisted})`, async () => {
      const child = createRuntime(mode, { persisted, parent: persisted });
      await child.emit("session_start");
      await child.emit("session_info_changed", { name: "renamed-without-agent-prefix" });
      await child.ask();
      await child.emit("agent_end", { type: "agent_end", messages: [] });
      assert.deepEqual(requests, [], "no child request may reach the Windows listener");
      await child.emit("session_shutdown");
      assert.equal(child.promptCount(), 0, "suppression must not bypass runtime cleanup");
    });
  }

  test(`headless Web ${mode} completion is filtered even without session_start`, async () => {
    const child = createRuntime(mode);
    await child.emit("agent_end", { type: "agent_end", messages: [] });
    assert.deepEqual(requests, []);
    await child.emit("session_shutdown");
  });

  test(`standalone ${mode} sender still notifies outside Pi Web`, async () => {
    delete process.env.PI_WEB_NO_OPEN;
    const cli = createRuntime(mode);
    await cli.emit("session_start");
    await cli.ask();
    await cli.emit("agent_end", { type: "agent_end", messages: [] });
    assert.equal(requests.length, 2);
    assert.ok(requests.every((payload) => payload.originKind === "terminal"));
    await cli.emit("session_shutdown");
  });
}

test("background child lifecycle does not suppress other Web tabs or user-created forks", async () => {
  const parent = createRuntime("rpc", { name: "parent-tab" });
  // A normal fork can carry parentSession and an agent-looking name; neither makes it a worker.
  const fork = createRuntime("rpc", { name: "Explore#abcd1234", persisted: true, parent: true });
  const child = createRuntime("print", { name: "renamed-worker" });
  await Promise.all([parent.emit("session_start"), fork.emit("session_start"), child.emit("session_start")]);
  await child.ask();
  await child.emit("agent_end", { type: "agent_end", messages: [] });
  await child.emit("session_shutdown");
  await parent.ask();
  await fork.ask();
  await Promise.all([parent.emit("agent_end"), fork.emit("agent_end")]);

  assert.equal(requests.length, 4);
  assert.ok(requests.every((payload) => payload.originKind === "pi-web"));
  for (const sessionName of ["parent-tab", "Explore#abcd1234"]) {
    assert.deepEqual(requests.filter((payload) => payload.sessionName === sessionName)
      .map((payload) => payload.notificationKind).sort(), ["ask-user", "turn-complete"]);
  }
  await Promise.all([parent.emit("session_shutdown"), fork.emit("session_shutdown")]);
});

test("TUI sender remains available inside a Web-marked environment", async () => {
  const tui = createRuntime("tui");
  await tui.emit("session_start");
  await tui.ask();
  await tui.emit("agent_end");
  assert.equal(requests.length, 2);
  assert.ok(requests.every((payload) => payload.originKind === "terminal"));
  await tui.emit("session_shutdown");
});

for (const marker of ["PI_SUBAGENT_CHILD", "TRELLIS_SUBAGENT_CHILD"]) {
  test(`legacy ${marker} process guard remains effective`, () => {
    process.env[marker] = "1";
    const child = createRuntime("rpc");
    assert.equal(child.handlerCount(), 0);
    assert.equal(child.promptCount(), 0);
  });
}

test("ask-user also honors a process guard set after extension registration", async () => {
  const runtime = createRuntime("rpc");
  await runtime.emit("session_start");
  process.env.PI_SUBAGENT_CHILD = "1";
  await runtime.ask();
  await runtime.emit("agent_end");
  assert.deepEqual(requests, []);
  await runtime.emit("session_shutdown");
});
