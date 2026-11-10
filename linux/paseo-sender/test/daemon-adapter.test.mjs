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
    this.agentSubscriptionId = null;
    this.subscriptionAck = "echo";
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
    // Deliberately inject a handshake-time callback to retain the early-wiring test.
    // Normal daemon broadcasts below require an agents subscription.
    for (const handler of this.attention) {
      handler({ agentId: "early", reason: "finished", timestamp: "2026-08-06T12:00:00Z" });
    }
  }

  async close() { this.state = { status: "disposed" }; this.agentSubscriptionId = null; }
  async fetchAgents(options) {
    this.calls.push(["agents", options]);
    const result = this.agentPages.shift();
    if (!options.subscribe) return result;
    this.agentSubscriptionId = options.subscribe.subscriptionId;
    const subscriptionId = this.subscriptionAck === "echo" ? this.agentSubscriptionId : this.subscriptionAck;
    return subscriptionId ? { ...result, subscriptionId } : result;
  }
  async fetchWorkspaces(options) { this.calls.push(["workspaces", options]); return this.workspacePages.shift(); }
  async fetchAgent(agentId) { this.calls.push(["agent", agentId]); return this.fetchAgentResult; }

  emitConnection(status) {
    this.state = status;
    if (status.status !== "connected") this.agentSubscriptionId = null;
    for (const handler of this.connection) handler(status);
  }

  emitAttention(event) {
    // Paseo 0.14 filters legacy clients by their agents subscription, not by page contents.
    if (this.state.status !== "connected" || !this.agentSubscriptionId) return;
    for (const handler of this.attention) handler(event);
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
  assert.deepEqual(client.calls[0][1], {
    page: { limit: 1 },
    subscribe: { subscriptionId: "paseo-sender-attention" },
  });
  assert.deepEqual(client.calls[1][1], { page: { limit: 1, cursor: "cursor-a" } });
  assert.deepEqual(client.calls[2][1], { page: { limit: 1 } });
  assert.deepEqual(client.calls[3][1], { page: { limit: 1, cursor: "cursor-w" } });
});

test("attention requires an agents subscription and resumes after reconnect reconciliation", async () => {
  const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
  await adapter.connect();
  const client = FakeClient.instance;
  const received = [];
  adapter.onAgentAttentionRequired((event) => received.push(event.agentId));
  const attentionFor = (agentId) => ({ agentId, reason: "finished", timestamp: "2026-11-10T08:00:00Z" });

  client.emitAttention(attentionFor("before-subscription"));
  assert.deepEqual(received, [], "a local callback alone must not subscribe to daemon broadcasts");
  client.agentPages.push(page([agentEntry("snapshot-agent")], false));
  await adapter.fetchAllAgents();
  client.emitAttention(attentionFor("snapshot-agent"));
  client.emitAttention(attentionFor("created-after-snapshot"));
  assert.deepEqual(received, ["snapshot-agent", "created-after-snapshot"]);

  client.emitConnection({ status: "disconnected" });
  client.emitConnection({ status: "connected" });
  client.emitAttention(attentionFor("before-resubscription"));
  assert.equal(received.length, 2, "disconnect must clear the server subscription");
  client.agentPages.push(page([agentEntry("snapshot-agent")], false));
  // The service reconciles on a connected transition by fetching the agent directory again.
  await adapter.fetchAllAgents();
  client.emitAttention(attentionFor("created-after-reconnect"));
  assert.deepEqual(received, ["snapshot-agent", "created-after-snapshot", "created-after-reconnect"]);

  await adapter.close();
  client.emitAttention(attentionFor("after-close"));
  assert.equal(received.length, 3);
});

test("agent reconciliation rejects a missing or mismatched subscription acknowledgment", async () => {
  for (const acknowledgment of [null, "another-subscription"]) {
    const adapter = new DaemonAdapter({ url: "ws://127.0.0.1:8787", clientId: "test", DaemonClientImpl: FakeClient });
    await adapter.connect();
    const client = FakeClient.instance;
    client.subscriptionAck = acknowledgment;
    client.agentPages.push(page([agentEntry("a")], false));
    await assert.rejects(adapter.fetchAllAgents(), /fetchAgents subscription not acknowledged/u);
    await adapter.close();
  }
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
