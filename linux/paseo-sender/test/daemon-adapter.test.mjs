import assert from "node:assert/strict";
import { setImmediate as waitImmediate } from "node:timers/promises";
import { test } from "node:test";

import { DaemonAdapter } from "../src/daemon.mjs";
import { createLogger } from "../src/privacy.mjs";

class FakeClient {
  static instance;

  constructor(config) {
    FakeClient.instance = this;
    this.config = config;
    this.connection = [];
    this.attention = [];
    this.events = [];
    this.agentPages = [];
    this.workspacePages = [];
    this.fetchAgentResult = null;
    this.state = { status: "idle" };
    this.serverInfo = { serverId: "server-1" };
    this.calls = [];
  }

  subscribeConnectionStatus(handler) { this.connection.push(handler); return () => {}; }
  onAgentAttentionRequired(handler) { this.attention.push(handler); return () => {}; }
  subscribe(handler) { this.events.push(handler); return () => {}; }
  getConnectionState() { return this.state; }
  getLastServerInfoMessage() { return this.serverInfo; }

  async connect() {
    assert.equal(this.connection.length, 1, "connection callback registered before connect");
    assert.equal(this.attention.length, 1, "attention callback registered before connect");
    assert.equal(this.events.length, 1, "lifecycle callback registered before connect");
    this.state = { status: "connected" };
    for (const handler of this.connection) handler(this.state);
    for (const handler of this.attention) {
      handler({ agentId: "early", reason: "finished", timestamp: "2026-08-06T12:00:00Z" });
    }
  }

  async close() { this.state = { status: "disposed" }; }
  async fetchAgents(options) { this.calls.push(["agents", options]); return this.agentPages.shift(); }
  async fetchWorkspaces(options) { this.calls.push(["workspaces", options]); return this.workspacePages.shift(); }
  async fetchAgent(agentId) { this.calls.push(["agent", agentId]); return this.fetchAgentResult; }

  emitConnection(status) {
    this.state = status;
    for (const handler of this.connection) handler(status);
  }

  emitLifecycle(event) { for (const handler of this.events) handler(event); }
}

function agentEntry(id) {
  return { agent: { id, workspaceId: "ws-1", pendingPermissions: [] }, project: { projectKey: "p" } };
}

function page(entries, hasMore, nextCursor = null, prevCursor = null) {
  return { entries, pageInfo: { nextCursor, prevCursor, hasMore } };
}

test("exact SDK cursor pages map entry.agent and workspace entries", async () => {
  const adapter = new DaemonAdapter({
    url: "ws://127.0.0.1:8787",
    clientId: "test",
    DaemonClientImpl: FakeClient,
  });
  await adapter.connect();
  const client = FakeClient.instance;
  client.agentPages.push(page([agentEntry("a")], true, "cursor-a"), page([agentEntry("b")], false, null, "cursor-a"));
  client.workspacePages.push(
    page([{ id: "ws-1" }], true, "cursor-w"),
    page([{ id: "ws-2" }], false, null, "cursor-w"),
  );

  assert.deepEqual((await adapter.fetchAllAgents({ limit: 1 })).map((agent) => agent.id), ["a", "b"]);
  assert.deepEqual((await adapter.fetchAllWorkspaces({ limit: 1 })).map((workspace) => workspace.id), ["ws-1", "ws-2"]);
  assert.deepEqual(client.calls[0][1], { page: { limit: 1 } });
  assert.deepEqual(client.calls[1][1], { page: { limit: 1, cursor: "cursor-a" } });
  assert.deepEqual(client.calls[2][1], { page: { limit: 1 } });
  assert.deepEqual(client.calls[3][1], { page: { limit: 1, cursor: "cursor-w" } });
});

test("workspace association uses public idPrefix pagination and exact match", async () => {
  const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
  await adapter.connect();
  const client = FakeClient.instance;
  client.workspacePages.push(page([{ id: "ws-10" }, { id: "ws-1" }], false));
  const workspace = await adapter.fetchWorkspace("ws-1");
  assert.equal(workspace.id, "ws-1");
  assert.deepEqual(client.calls.at(-1)[1], { filter: { idPrefix: "ws-1" }, page: { limit: 100 } });
});

test("malformed, repeated cursor, and incomplete pages reject instead of returning empty", async () => {
  for (const scenario of ["malformed", "repeated", "incomplete"]) {
    const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
    await adapter.connect();
    const client = FakeClient.instance;
    if (scenario === "malformed") client.agentPages.push({ agents: [] });
    if (scenario === "repeated") {
      client.agentPages.push(page([agentEntry("a")], true, "same"), page([agentEntry("b")], true, "same"));
    }
    if (scenario === "incomplete") client.agentPages.push(page([agentEntry("a")], true, "next"));
    await assert.rejects(
      adapter.fetchAllAgents({ limit: 1, maxPages: scenario === "incomplete" ? 1 : 3 }),
      /malformed|repeated|incomplete/u,
    );
  }
});

test("early callbacks are observed, reconnect transitions exposed, async rejection contained", async () => {
  const errors = [];
  const adapter = new DaemonAdapter({
    url: "ws://127.0.0.1:8787",
    clientId: "test",
    DaemonClientImpl: FakeClient,
    logger: createLogger({
      info() {},
      warn() {},
      error(line) { errors.push(JSON.parse(line)); },
    }),
  });
  const attention = [];
  const connections = [];
  adapter.onAgentAttentionRequired(async (event) => {
    attention.push(event.agentId);
    throw new Error("contained");
  });
  adapter.subscribeConnectionStatus((status) => connections.push(status.status));
  await adapter.connect();
  FakeClient.instance.emitConnection({ status: "disconnected", reason: "test" });
  FakeClient.instance.emitConnection({ status: "connected" });
  await waitImmediate();
  assert.deepEqual(attention, ["early"]);
  assert.deepEqual(connections, ["connected", "disconnected", "connected"]);
  assert.equal(errors.some((entry) => entry.event === "attention_callback_failed"), true);
});

test("fetchAgent accepts only exact public {agent, project} identity", async () => {
  const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
  await adapter.connect();
  FakeClient.instance.fetchAgentResult = { agent: { id: "a" }, project: { projectKey: "p" } };
  assert.equal((await adapter.fetchAgent("a")).agent.id, "a");
  FakeClient.instance.fetchAgentResult = { id: "a" };
  await assert.rejects(adapter.fetchAgent("a"), /malformed/u);
});

test("adapter declares selectiveAgentTimeline capability matching protocol literal", async () => {
  const { CLIENT_CAPS } = await import("@getpaseo/protocol/client-capabilities");
  assert.equal(CLIENT_CAPS.selectiveAgentTimeline, "selective_agent_timeline");

  const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
  await adapter.connect();
  assert.deepEqual(FakeClient.instance.config.capabilities, {
    [CLIENT_CAPS.selectiveAgentTimeline]: true,
  });
});

test("adapter appVersion stays parseable for daemon feature negotiation", async () => {
  const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
  await adapter.connect();
  const appVersion = FakeClient.instance.config.appVersion;
  // daemon 按 semver 比较 appVersion（>=0.1.45 才可见全部 provider）；非 semver 会被当作 legacy。
  assert.match(appVersion, /^\d+\.\d+\.\d+/);
  const [major, minor, patch] = appVersion.replace(/-.*$/, "").split(".").map(Number);
  assert.ok(
    major > 0 || (major === 0 && minor > 1) || (major === 0 && minor === 1 && patch >= 45),
    `appVersion ${appVersion} must clear daemon MIN_VERSION_ALL_PROVIDERS 0.1.45`,
  );
});
