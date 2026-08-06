import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { DurableStore } from "../src/store.mjs";
import { Reconciler } from "../src/reconcile.mjs";
import { PaseoSenderService } from "../src/service.mjs";
import { eventFingerprint } from "../src/privacy.mjs";
import { WindowsDelivery } from "../src/delivery.mjs";

function tempDir() { return mkdtempSync(join(tmpdir(), "paseo-sender-recon-")); }

function makeConfig(stateDir, overrides = {}) {
  return {
    enabled: true,
    deliveryMode: "shadow",
    daemonUrl: "ws://127.0.0.1:9",
    clientId: "test",
    windowsEndpoint: "http://127.0.0.1:23118/notify",
    windowsToken: "token",
    timeoutMs: 2000,
    stateDir,
    healthIntervalMs: 60_000,
    leaseStaleMs: 15_000,
    finishedTtlMs: 30 * 60 * 1000,
    backoffInitialMs: 1000,
    backoffMaxMs: 60_000,
    globalConcurrency: 2,
    detailedSummary: false,
    titleMaxCodePoints: 72,
    bodyMaxCodePoints: 220,
    agentDisplayNameFallback: "Agent",
    configPath: "",
    ...overrides,
  };
}

class FakeDaemon {
  constructor({ agents = [], workspaces = [], fetchAgent } = {}) {
    this.agents = agents;
    this.workspaces = workspaces;
    this.fetchAgentImpl = fetchAgent || (async (agentId) => {
      const agent = this.agents.find((entry) => entry.id === agentId);
      return agent ? { agent, project: { projectKey: "p" } } : null;
    });
    this.attention = null;
    this.lifecycle = null;
    this.connections = [];
    this.connected = true;
    this.reconcileCalls = 0;
    this.activeReconciles = 0;
    this.maxActiveReconciles = 0;
    this.reconcileBarrier = null;
  }

  onAgentAttentionRequired(handler) { this.attention = handler; return () => { this.attention = null; }; }
  subscribeLifecycle(handler) { this.lifecycle = handler; return () => { this.lifecycle = null; }; }
  subscribeConnectionStatus(handler) { this.connections.push(handler); return () => {}; }
  async connect() { return { connected: true, serverId: "server-1" }; }
  async close() { this.connected = false; }
  isConnected() { return this.connected; }
  getServerId() { return this.connected ? "server-1" : null; }
  async fetchAllAgents() {
    this.reconcileCalls += 1;
    this.activeReconciles += 1;
    this.maxActiveReconciles = Math.max(this.maxActiveReconciles, this.activeReconciles);
    try {
      if (this.reconcileBarrier) await this.reconcileBarrier;
      return this.agents;
    } finally {
      this.activeReconciles -= 1;
    }
  }
  async fetchAllWorkspaces() { return this.workspaces; }
  async fetchAgent(agentId) { return this.fetchAgentImpl(agentId); }
  async fetchWorkspace(id) { return this.workspaces.find((workspace) => workspace.id === id) || null; }
  async emitAttention(event) { return this.attention?.(event); }
  async emitLifecycle(event) { return this.lifecycle?.(event); }
  emitConnection(status) { return this.connections.map((handler) => handler(status)); }
}

const NOW = Date.parse("2026-08-06T12:00:00.000Z");
const WORKSPACES = [{ id: "ws-1" }];

function finishedEvent(agentId = "agent-1") {
  return { agentId, reason: "finished", timestamp: "2026-08-06T11:59:00.000Z", shouldNotify: false };
}

function permissionEvent(agentId = "agent-1") {
  return { agentId, reason: "permission", timestamp: "2026-08-06T11:59:00.000Z", shouldNotify: false };
}

test("first run baselines completion and creates only snapshot-backed permission", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir, { now: () => NOW });
    await store.load();
    const reconciler = new Reconciler({ store, now: () => NOW });
    await reconciler.reconcile({
      serverId: "server-1",
      isFirstRun: true,
      workspaces: WORKSPACES,
      agents: [
        { id: "done", workspaceId: "ws-1", attentionReason: "finished", attentionTimestamp: "2026-08-06T11:00:00.000Z", pendingPermissions: [] },
        { id: "perm", workspaceId: "ws-1", pendingPermissions: [{ id: "r1" }, { id: "r2" }] },
      ],
    });
    assert.equal(store.getWatermark("server-1", "done"), "2026-08-06T11:00:00.000Z");
    assert.equal(store.listItems().length, 1);
    assert.deepEqual(store.listItems()[0].permissionRequestIds.sort(), ["r1", "r2"]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("reconnect baselines an agent with no persisted watermark instead of replaying history", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir, { now: () => NOW });
    await store.load();
    const reconciler = new Reconciler({ store, now: () => NOW });
    await reconciler.reconcile({ serverId: "server-1", isFirstRun: true, workspaces: [], agents: [] });
    await reconciler.reconcile({
      serverId: "server-1",
      isFirstRun: false,
      workspaces: WORKSPACES,
      agents: [{
        id: "new-agent",
        workspaceId: "ws-1",
        attentionReason: "finished",
        attentionTimestamp: "2026-08-06T11:00:00.000Z",
        pendingPermissions: [],
      }],
    });
    assert.equal(store.getWatermark("server-1", "new-agent"), "2026-08-06T11:00:00.000Z");
    assert.equal(store.listItems().length, 0, "no persisted watermark means baseline, not historical replay");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("reconnect uses workspace authority, enqueues newer completion, and prunes on complete empty list", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir, { now: () => NOW });
    await store.load();
    const reconciler = new Reconciler({ store, now: () => NOW });
    await reconciler.reconcile({
      serverId: "server-1", isFirstRun: true, workspaces: WORKSPACES,
      agents: [{ id: "a", workspaceId: "ws-1", attentionReason: "finished", attentionTimestamp: "2026-08-06T10:00:00.000Z", pendingPermissions: [] }],
    });
    await reconciler.reconcile({
      serverId: "server-1", isFirstRun: false, workspaces: WORKSPACES,
      agents: [
        { id: "a", workspaceId: "ws-1", attentionReason: "finished", attentionTimestamp: "2026-08-06T11:00:00.000Z", pendingPermissions: [] },
        { id: "missing-ts", workspaceId: "ws-1", attentionReason: "finished", pendingPermissions: [] },
      ],
    });
    assert.equal(store.listItems().length, 1);
    assert.equal(store.hasTimestampWarning("server-1", "missing-ts"), true);
    await reconciler.reconcile({ serverId: "server-1", isFirstRun: false, workspaces: [], agents: [] });
    assert.equal(store.listItems().length, 0, "complete empty snapshot prunes stale pending completion");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("authority outage persists attention before processed marker and recovers after restart", async () => {
  const dir = tempDir();
  let now = NOW;
  try {
    const agent = { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] };
    const failingDaemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES, fetchAgent: async () => { throw new Error("offline"); } });
    const first = new PaseoSenderService({
      config: makeConfig(dir), daemon: failingDaemon, now: () => now,
      store: new DurableStore(dir, { now: () => now }),
    });
    await first.start();
    await failingDaemon.emitAttention(finishedEvent());
    assert.equal(first.store.listPendingAuthority().length, 1);
    const fp = eventFingerprint({ serverId: "server-1", agentId: "agent-1", reason: "finished", timestamp: "2026-08-06T11:59:00.000Z" });
    assert.equal(first.store.hasProcessedEvent(fp), false);
    await first.stop();

    now += 2000;
    const healthyDaemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const second = new PaseoSenderService({
      config: makeConfig(dir), daemon: healthyDaemon, now: () => now,
      store: new DurableStore(dir, { now: () => now }),
    });
    await second.start();
    await waitUntil(() => second.store.listItems().length === 1);
    assert.equal(second.store.listPendingAuthority().length, 0);
    assert.equal(second.store.hasProcessedEvent(fp), true);
    await second.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("permission request is correlation-only before attention", async () => {
  const dir = tempDir();
  try {
    const agent = { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] };
    const daemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const service = new PaseoSenderService({ config: makeConfig(dir), daemon, now: () => NOW, store: new DurableStore(dir, { now: () => NOW }) });
    await service.start();
    await daemon.emitLifecycle({ type: "agent_permission_request", agentId: "agent-1", request: { id: "req-1" } });
    assert.equal(service.store.listItems().length, 0);
    await daemon.emitAttention(permissionEvent());
    assert.equal(service.store.listItems().length, 1);
    assert.deepEqual(service.store.listItems()[0].permissionRequestIds, ["req-1"]);
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("attention before permission request remains resolving then completes", async () => {
  const dir = tempDir();
  try {
    const agent = { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] };
    const daemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const service = new PaseoSenderService({ config: makeConfig(dir), daemon, now: () => NOW, store: new DurableStore(dir, { now: () => NOW }) });
    await service.start();
    await daemon.emitAttention(permissionEvent());
    assert.equal(service.store.listPendingAuthority().length, 1);
    assert.equal(service.store.listItems().length, 0);
    await daemon.emitLifecycle({ type: "agent_permission_request", agentId: "agent-1", request: { id: "req-late" } });
    assert.equal(service.store.listPendingAuthority().length, 0);
    assert.deepEqual(service.store.listItems()[0].permissionRequestIds, ["req-late"]);
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("complete permission snapshot prunes stale correlation so later attention cannot resurrect it", async () => {
  const dir = tempDir();
  try {
    const agent = { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] };
    const daemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    await service.start();
    await daemon.emitLifecycle({ type: "agent_permission_request", agentId: "agent-1", request: { id: "stale-request" } });
    await daemon.emitAttention(permissionEvent());
    assert.deepEqual(service.store.listItems()[0].permissionRequestIds, ["stale-request"]);

    await Promise.all(daemon.emitConnection({ status: "connected" }));
    await waitUntil(() => service.store.listItems().length === 0);

    await daemon.emitAttention({
      agentId: "agent-1",
      reason: "permission",
      timestamp: "2026-08-06T11:59:01.000Z",
      shouldNotify: false,
    });
    assert.equal(service.store.listItems().length, 0);
    assert.equal(service.store.listPendingAuthority().length, 1, "attention waits for a current request ID");
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("reconnect reconciliation is serialized and burst transitions coalesce into one later rerun", async () => {
  const dir = tempDir();
  try {
    const daemon = new FakeDaemon({ agents: [], workspaces: [] });
    const service = new PaseoSenderService({ config: makeConfig(dir), daemon });
    await service.start();
    const afterStart = daemon.reconcileCalls;
    let release;
    daemon.reconcileBarrier = new Promise((resolve) => { release = resolve; });
    const callbacks = [...daemon.emitConnection({ status: "connected" }), ...daemon.emitConnection({ status: "connected" })];
    await new Promise((resolve) => setTimeout(resolve, 10));
    release();
    await Promise.all(callbacks);
    // start + one active reconnect pass + exactly one coalesced later rerun
    await waitUntil(() => daemon.reconcileCalls >= afterStart + 2);
    assert.equal(daemon.maxActiveReconciles, 1);
    assert.equal(daemon.reconcileCalls, afterStart + 2, "burst reconnect signals produce one active pass and one later rerun");
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("stop waits for active reconcile and prevents post-stop snapshot writes", async () => {
  const dir = tempDir();
  try {
    const daemon = new FakeDaemon({ agents: [], workspaces: [] });
    let release;
    daemon.reconcileBarrier = new Promise((resolve) => { release = resolve; });
    const store = new DurableStore(dir, { now: () => NOW });
    const service = new PaseoSenderService({ config: makeConfig(dir), daemon, store, now: () => NOW });
    const startPromise = service.start();
    await waitUntil(() => daemon.activeReconciles === 1);
    const stopPromise = service.stop();
    release();
    const [startResult] = await Promise.all([startPromise, stopPromise]);
    assert.deepEqual(startResult, { started: false, reason: "stopped-during-start" });
    const generation = store.state.generation;
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(store.corrupt, false);
    assert.equal(store.state.generation, generation, "no reconcile transaction runs after stop returns");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("stop during active authority fetch preserves the durable attention without late enqueue", async () => {
  const dir = tempDir();
  try {
    let releaseFetch;
    const fetchBarrier = new Promise((resolve) => { releaseFetch = resolve; });
    const agent = { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] };
    const daemon = new FakeDaemon({
      agents: [agent],
      workspaces: WORKSPACES,
      fetchAgent: async () => {
        await fetchBarrier;
        return { agent, project: { projectKey: "p" } };
      },
    });
    const store = new DurableStore(dir, { now: () => NOW });
    const service = new PaseoSenderService({ config: makeConfig(dir), daemon, store, now: () => NOW });
    await service.start();
    const attentionPromise = daemon.emitAttention(finishedEvent());
    await waitUntil(() => service.globalInFlight === 1);
    const stopPromise = service.stop();
    releaseFetch();
    await Promise.all([attentionPromise, stopPromise]);
    assert.equal(store.corrupt, false);
    assert.equal(store.listItems().length, 0);
    assert.equal(store.listPendingAuthority().length, 1, "restart can safely retry the persisted attention");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("stop aborts active delivery and waits for its durable retry transition", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir, { now: () => NOW });
    await store.load();
    await store.transaction(() => store.upsertItem({
      serverId: "server-1",
      agentId: "agent-1",
      workspaceId: "ws-1",
      kind: "finished",
      eventTimestamp: "2026-08-06T11:59:00.000Z",
      eventMs: Date.parse("2026-08-06T11:59:00.000Z"),
    }));
    let notifyStarted = false;
    let finishNotify;
    const delivery = {
      probeHealth: async () => ({ ok: false, ready: false, reason: "offline-test" }),
      notify: async () => {
        notifyStarted = true;
        return new Promise((resolve) => { finishNotify = () => resolve({ code: "transport" }); });
      },
      close: async () => ({ code: "transport" }),
      abortAll() { finishNotify?.(); },
    };
    const daemon = new FakeDaemon({
      agents: [{ id: "agent-1", workspaceId: "ws-1", title: "Agent", pendingPermissions: [] }],
      workspaces: WORKSPACES,
    });
    const service = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }),
      daemon,
      delivery,
      store,
      now: () => NOW,
    });
    await service.start();
    await waitUntil(() => notifyStarted);
    await service.stop();
    const item = store.listItems()[0];
    assert.equal(service.globalInFlight, 0);
    assert.equal(store.corrupt, false);
    assert.equal(item.status, "pending");
    assert.equal(item.lastResult, "transport");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("delivery semantics: first retry is 1s, finished suppress ends, permission suppress retains", async () => {
  const dir = tempDir();
  let now = NOW;
  try {
    const responses = ["retry", "suppressed-active-agent", "suppressed-active-agent"];
    const delivery = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async () => ({ status: 200, ok: true, text: async () => responses.shift() }),
    });
    const store = new DurableStore(dir, { now: () => now });
    await store.load();
    await store.transaction(() => {
      store.upsertItem({ serverId: "s", agentId: "retry", workspaceId: "w", kind: "finished", eventTimestamp: "2026-08-06T11:59:00.000Z", eventMs: NOW });
      store.upsertItem({ serverId: "s", agentId: "finish", workspaceId: "w", kind: "finished", eventTimestamp: "2026-08-06T11:59:01.000Z", eventMs: NOW });
      store.syncPermissionSet("s", "permission", "w", ["r1"], { eventTimestamp: "2026-08-06T11:59:02.000Z", eventMs: NOW });
    });
    const service = new PaseoSenderService({ config: makeConfig(dir, { deliveryMode: "live" }), store, daemon: new FakeDaemon(), delivery, now: () => now });
    for (const item of store.listItems()) service.agentDisplayNames.set(item.agentKey, "Agent");
    await service.deliverOne(store.listItems().find((item) => item.agentId === "retry"));
    const retry = store.listItems().find((item) => item.agentId === "retry");
    assert.ok(retry.nextAttemptAt - now >= 1000);
    assert.ok(retry.nextAttemptAt - now <= 1200, "first retry stays on the 1s jitter band, not 2s");
    await service.deliverOne(store.listItems().find((item) => item.agentId === "finish"));
    await service.deliverOne(store.listItems().find((item) => item.agentId === "permission"));
    assert.equal(store.listItems().some((item) => item.agentId === "finish"), false);
    assert.equal(store.listItems().find((item) => item.agentId === "permission").status, "pending");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("new permission closes superseded UUID before posting its new UUID", async () => {
  const dir = tempDir();
  try {
    const requests = [];
    const delivery = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async (url, options) => {
        requests.push({ url: String(url), body: JSON.parse(options.body) });
        return { status: 200, ok: true, text: async () => "ok" };
      },
    });
    const store = new DurableStore(dir);
    await store.load();
    let oldId;
    let newId;
    await store.transaction(() => {
      const old = store.syncPermissionSet("s", "a", "w", ["old"]);
      old.status = "delivered";
      old.desktopShownAt = Date.now();
      oldId = old.notificationId;
      store.resolvePermissionId("s", "a", "old");
      newId = store.syncPermissionSet("s", "a", "w", ["new"]).notificationId;
    });
    const service = new PaseoSenderService({ config: makeConfig(dir, { deliveryMode: "live" }), store, daemon: new FakeDaemon(), delivery });
    service.agentDisplayNames.set(store.listItems()[0].agentKey, "Agent");
    await service.deliverOne(store.listItems()[0]);
    assert.match(requests[0].url, /\/paseo\/close$/u);
    assert.equal(requests[0].body.notificationId, oldId);
    assert.match(requests[1].url, /\/notify$/u);
    assert.equal(requests[1].body.notificationId, newId);
    assert.notEqual(oldId, newId);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("superseded close retry survives partial resolve and later closes old before notifying new", async () => {
  const dir = tempDir();
  let now = NOW;
  try {
    const requests = [];
    const responses = ["retry", "ok", "ok"];
    const delivery = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async (url, options) => {
        requests.push({ url: String(url), body: JSON.parse(options.body) });
        return { status: 200, ok: true, text: async () => responses.shift() };
      },
    });
    const store = new DurableStore(dir, { now: () => now });
    await store.load();
    let oldId;
    let newId;
    await store.transaction(() => {
      const old = store.syncPermissionSet("s", "a", "w", ["old"]);
      old.status = "delivered";
      old.desktopShownAt = now;
      oldId = old.notificationId;
      store.resolvePermissionId("s", "a", "old");
      const next = store.syncPermissionSet("s", "a", "w", ["new-a", "new-b"]);
      newId = next.notificationId;
    });
    const service = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }), store, daemon: new FakeDaemon(), delivery, now: () => now,
    });
    service.agentDisplayNames.set(store.listItems()[0].agentKey, "Agent");

    await service.deliverOne(store.listItems()[0]);
    assert.equal(requests.length, 1);
    assert.match(requests[0].url, /\/paseo\/close$/u);
    assert.equal(requests[0].body.notificationId, oldId);
    assert.equal(store.listItems()[0].supersededNotificationId, oldId);

    await store.transaction(() => store.resolvePermissionId("s", "a", "new-a"));
    assert.equal(store.listItems()[0].notificationId, newId);
    assert.deepEqual(store.listItems()[0].permissionRequestIds, ["new-b"]);
    now = store.listItems()[0].nextAttemptAt;
    await service.deliverOne(store.listItems()[0]);

    assert.equal(requests.length, 3);
    assert.equal(requests[1].body.notificationId, oldId);
    assert.match(requests[2].url, /\/notify$/u);
    assert.equal(requests[2].body.notificationId, newId);
    assert.equal(store.listItems()[0].status, "delivered");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("shown permission resolve and agent delete POST exact UUID-only close", async () => {
  const dir = tempDir();
  try {
    const closeBodies = [];
    const delivery = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async (_url, options) => {
        closeBodies.push(JSON.parse(options.body));
        return { status: 200, ok: true, text: async () => "ok" };
      },
    });
    const store = new DurableStore(dir);
    await store.load();
    await store.transaction(() => {
      const item = store.syncPermissionSet("s", "a", "w", ["r1"]);
      item.status = "delivered";
      item.desktopShownAt = Date.now();
      store.resolvePermissionId("s", "a", "r1");
    });
    const id = store.listItems()[0].notificationId;
    const service = new PaseoSenderService({ config: makeConfig(dir, { deliveryMode: "live" }), store, daemon: new FakeDaemon(), delivery });
    await service.closeOne(store.listItems()[0]);
    assert.deepEqual(closeBodies[0], { originKind: "paseo", version: 1, notificationId: id });
    assert.equal(store.listItems().length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("authoritative agent title appears in Windows payload and is never persisted", async () => {
  const dir = tempDir();
  try {
    const agent = { id: "agent-1", workspaceId: "ws-1", title: "My Real Agent Title", pendingPermissions: [] };
    const daemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const notifyBodies = [];
    const delivery = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async (url, options) => {
        if (String(url).includes("/notify")) notifyBodies.push(JSON.parse(options.body));
        return { status: 200, ok: true, text: async () => "ok" };
      },
    });
    const service = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }),
      daemon,
      delivery,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    await service.start();
    await daemon.emitAttention(finishedEvent());
    await waitUntil(() => notifyBodies.length >= 1);
    assert.equal(notifyBodies[0].title, "My Real Agent Title");
    assert.equal(notifyBodies[0].body, "已完成");

    const stateRaw = readFileSync(join(dir, "state.json"), "utf8");
    const outboxRaw = readFileSync(join(dir, "outbox.json"), "utf8");
    assert.equal(stateRaw.includes("My Real Agent Title"), false);
    assert.equal(outboxRaw.includes("My Real Agent Title"), false);
    assert.equal(existsSync(join(dir, "transaction.json")), false);

    await service.stop();

    // After restart the ephemeral map is empty; delivery waits until reconcile repopulates.
    const notifyBodies2 = [];
    const delivery2 = new WindowsDelivery({
      notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
      fetchImpl: async (url, options) => {
        if (String(url).includes("/notify")) notifyBodies2.push(JSON.parse(options.body));
        return { status: 200, ok: true, text: async () => "ok" };
      },
    });
    // Seed a pending item without going through authority (simulates restart with durable outbox).
    const store2 = new DurableStore(dir, { now: () => NOW });
    await store2.load();
    // First-run already initialized; enqueue a finished item manually as if it survived restart.
    await store2.transaction(() => {
      store2.upsertItem({
        serverId: "server-1", agentId: "agent-1", workspaceId: "ws-1", kind: "finished",
        eventTimestamp: "2026-08-06T11:58:00.000Z", eventMs: Date.parse("2026-08-06T11:58:00.000Z"),
      });
    });
    const second = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }),
      daemon: new FakeDaemon({ agents: [agent], workspaces: WORKSPACES }),
      delivery: delivery2,
      now: () => NOW,
      store: store2,
    });
    // Before start, no display name => pump would skip.
    assert.equal(second.agentDisplayNames.size, 0);
    await second.start();
    // Reconcile repopulates the title from the snapshot and allows delivery.
    await waitUntil(() => second.agentDisplayNames.size >= 1);
    assert.equal([...second.agentDisplayNames.values()][0], "My Real Agent Title");
    await second.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("route-unresolved permission blocks authorityReady and later recovers", async () => {
  const dir = tempDir();
  try {
    const agent = {
      id: "agent-1",
      workspaceId: "ws-missing",
      title: "Blocked",
      pendingPermissions: [{ id: "r1" }],
    };
    let workspaces = []; // missing workspace authority first
    const daemon = new FakeDaemon({
      agents: [agent],
      workspaces: [],
    });
    // Override so we can swap workspace availability.
    daemon.fetchAllWorkspaces = async () => workspaces;
    daemon.fetchAllAgents = async () => {
      daemon.reconcileCalls += 1;
      return [agent];
    };

    let refreshes = 0;
    const service = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live", healthIntervalMs: 60_000 }),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
      delivery: {
        probeHealth: async () => ({ ok: true, ready: true }),
        notify: async () => ({ code: "ok" }),
        close: async () => ({ code: "ok" }),
        abortAll() {},
      },
      lease: {
        load: async () => null,
        refresh: async () => { refreshes += 1; return { refreshed: true }; },
        isHealthy: () => false,
      },
    });
    await service.start();
    assert.equal(service.authorityReady, false, "unresolved permission keeps authorityReady false");
    assert.equal(service.store.listItems().length, 0, "permission not silently queued without route");
    assert.equal(refreshes, 0);

    // Recover: workspace becomes available and a reconcile retry runs via reconnect signal.
    workspaces = [{ id: "ws-missing" }];
    await Promise.all(daemon.emitConnection({ status: "connected" }));
    await waitUntil(() => service.authorityReady === true);
    assert.equal(service.store.listItems().length, 1);
    assert.deepEqual(service.store.listItems()[0].permissionRequestIds, ["r1"]);
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("server change mid-fetch discards stale snapshot and reruns", async () => {
  const dir = tempDir();
  try {
    let call = 0;
    let currentServer = "server-A";
    const daemon = new FakeDaemon({ agents: [], workspaces: [] });
    daemon.getServerId = () => currentServer;
    daemon.fetchAllAgents = async () => {
      call += 1;
      daemon.reconcileCalls += 1;
      if (call === 1) {
        // Mid-fetch identity flip: snapshot is for server-A but identity becomes server-B.
        currentServer = "server-B";
        return [{ id: "stale-agent", workspaceId: "ws-1", pendingPermissions: [{ id: "stale" }] }];
      }
      return [{ id: "fresh-agent", workspaceId: "ws-1", pendingPermissions: [{ id: "fresh" }] }];
    };
    daemon.fetchAllWorkspaces = async () => [{ id: "ws-1" }];

    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    await service.start();
    // Wait for the automatic pending rerun after discard.
    await waitUntil(() => call >= 2);
    await waitUntil(() => service.store.listItems().length === 1);
    assert.equal(service.store.listItems()[0].agentId, "fresh-agent");
    assert.deepEqual(service.store.listItems()[0].permissionRequestIds, ["fresh"]);
    assert.equal(service.store.listItems().some((item) => item.agentId === "stale-agent"), false);
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("server change during workspace authority RPC preserves pending attention", async () => {
  const dir = tempDir();
  try {
    let currentServer = "server-1";
    const daemon = new FakeDaemon({ agents: [], workspaces: [] });
    daemon.getServerId = () => daemon.connected ? currentServer : null;
    daemon.fetchAgent = async () => ({
      agent: { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] },
      project: { projectKey: "p" },
    });
    daemon.fetchWorkspace = async () => {
      currentServer = "server-2";
      return { id: "ws-1" };
    };
    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    await service.start();
    await daemon.emitAttention(finishedEvent());
    assert.equal(service.store.listItems().length, 0);
    assert.equal(service.store.listPendingAuthority().length, 1);
    assert.equal(service.store.listPendingAuthority()[0].lastError, "server-changed");
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("disconnect during active reconcile produces a current rerun and never concurrent passes", async () => {
  const dir = tempDir();
  try {
    const daemon = new FakeDaemon({ agents: [], workspaces: [] });
    let release;
    daemon.reconcileBarrier = new Promise((resolve) => { release = resolve; });
    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    // Don't await start fully — it will block on first reconcile barrier.
    const startPromise = service.start();
    await new Promise((resolve) => setTimeout(resolve, 20));
    // Signal reconnect while first pass is running.
    daemon.emitConnection({ status: "connected" });
    daemon.emitConnection({ status: "connected" });
    release();
    await startPromise;
    await waitUntil(() => daemon.reconcileCalls >= 2);
    assert.equal(daemon.maxActiveReconciles, 1, "no duplicate concurrent reconciles");
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("added-ID permission attention starts new episode; partial resolve and same-set reconnect preserve", async () => {
  const dir = tempDir();
  try {
    // Start without snapshot permissions so first-run reconcile creates no outbox item.
    const agent = {
      id: "agent-1",
      workspaceId: "ws-1",
      title: "Perm Agent",
      pendingPermissions: [],
    };
    const daemon = new FakeDaemon({ agents: [agent], workspaces: WORKSPACES });
    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      now: () => NOW,
      store: new DurableStore(dir, { now: () => NOW }),
    });
    await service.start();
    assert.equal(service.store.listItems().length, 0);

    // Request-before-attention: correlation only, never creates a popup.
    await daemon.emitLifecycle({ type: "agent_permission_request", agentId: "agent-1", request: { id: "r1" } });
    assert.equal(service.store.listItems().length, 0);

    // Attention + correlation resolves into one permission card.
    await daemon.emitAttention(permissionEvent());
    await waitUntil(() => service.store.listItems().length === 1);
    const first = service.store.listItems()[0];
    const firstId = first.notificationId;
    assert.deepEqual(first.permissionRequestIds, ["r1"]);

    // Mark delivered to simulate a shown card.
    await service.store.transaction(() => {
      const item = service.store.getItem(first.agentKey);
      item.status = "delivered";
      item.desktopShownAt = NOW;
    });

    // Same-set ordinary reconnect preserves UUID/delivered.
    agent.pendingPermissions = [{ id: "r1" }];
    await Promise.all(daemon.emitConnection({ status: "connected" }));
    await waitUntil(() => daemon.reconcileCalls >= 2);
    const afterSame = service.store.listItems()[0];
    assert.equal(afterSame.notificationId, firstId);
    assert.equal(afterSame.status, "delivered");

    // Subset-only change (partial resolution) preserves UUID/card.
    let midId;
    await service.store.transaction(() => {
      // Expand then shrink to prove subset path.
      const expanded = service.store.syncPermissionSet("server-1", "agent-1", "ws-1", ["r1", "r-temp"]);
      expanded.status = "delivered";
      expanded.desktopShownAt = NOW;
      const subset = service.store.syncPermissionSet("server-1", "agent-1", "ws-1", ["r1"]);
      midId = subset.notificationId;
      assert.equal(subset.notificationId, expanded.notificationId);
      assert.equal(subset.status, "delivered");
    });

    // Added-ID attention: new episode with superseded old UUID.
    await service.store.transaction(() => {
      const next = service.store.syncPermissionSet("server-1", "agent-1", "ws-1", ["r1", "r2"]);
      assert.notEqual(next.notificationId, midId);
      assert.equal(next.status, "pending");
      assert.equal(next.supersededNotificationId, midId);
    });

    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("foreign-server pending authority is preserved and never resolved against current daemon", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir, { now: () => NOW });
    await store.load();
    const foreignFp = eventFingerprint({
      serverId: "server-FOREIGN",
      agentId: "agent-1",
      reason: "finished",
      timestamp: "2026-08-06T11:59:00.000Z",
    });
    await store.transaction(() => store.recordPendingAttention({
      eventFp: foreignFp,
      serverId: "server-FOREIGN",
      agentId: "agent-1",
      reason: "finished",
      timestamp: "2026-08-06T11:59:00.000Z",
      eventMs: Date.parse("2026-08-06T11:59:00.000Z"),
    }));

    let fetchAgentCalls = 0;
    const daemon = new FakeDaemon({
      agents: [{ id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] }],
      workspaces: WORKSPACES,
      fetchAgent: async () => {
        fetchAgentCalls += 1;
        return { agent: { id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] }, project: null };
      },
    });
    const service = new PaseoSenderService({
      config: makeConfig(dir),
      daemon,
      store,
      now: () => NOW,
    });
    await service.start();
    // Pump would try authority; foreign server must not be resolved.
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(store.getPendingAuthority(foreignFp) != null, true);
    assert.equal(fetchAgentCalls, 0, "must not call fetchAgent for foreign serverId");
    await service.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("HTTP 403 retains completion/permission/close items; body invalid terminalizes", async () => {
  const dir = tempDir();
  let now = NOW;
  try {
    const store = new DurableStore(dir, { now: () => now });
    await store.load();
    await store.transaction(() => {
      store.upsertItem({
        serverId: "s", agentId: "finish", workspaceId: "w", kind: "finished",
        eventTimestamp: "2026-08-06T11:59:00.000Z", eventMs: NOW,
      });
      store.syncPermissionSet("s", "perm", "w", ["r1"], {
        eventTimestamp: "2026-08-06T11:59:01.000Z", eventMs: NOW,
      });
      const closing = store.syncPermissionSet("s", "closing", "w", ["r2"], {
        eventTimestamp: "2026-08-06T11:59:02.000Z", eventMs: NOW,
      });
      closing.status = "delivered";
      closing.desktopShownAt = NOW;
      store.resolvePermissionId("s", "closing", "r2");
    });

    // Seed display names so pump/deliverOne is not blocked by missing ephemeral map.
    const service403 = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }),
      store,
      daemon: new FakeDaemon(),
      delivery: new WindowsDelivery({
        notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
        fetchImpl: async () => ({ status: 403, ok: false, text: async () => "forbidden" }),
      }),
      now: () => now,
    });
    for (const item of store.listItems()) {
      service403.agentDisplayNames.set(item.agentKey, "Agent");
    }

    const finish = store.listItems().find((item) => item.agentId === "finish");
    const perm = store.listItems().find((item) => item.agentId === "perm");
    const closing = store.listItems().find((item) => item.agentId === "closing");
    await service403.deliverOne(finish);
    await service403.deliverOne(perm);
    await service403.closeOne(closing);

    assert.equal(store.getItem(finish.agentKey).status, "pending");
    assert.equal(store.getItem(finish.agentKey).lastResult, "auth");
    assert.equal(store.getItem(perm.agentKey).status, "pending");
    assert.equal(store.getItem(perm.agentKey).lastResult, "auth");
    assert.equal(store.getItem(closing.agentKey).status, "closing");
    assert.equal(store.getItem(closing.agentKey).lastResult, "auth");

    // Body invalid terminalizes.
    const serviceInvalid = new PaseoSenderService({
      config: makeConfig(dir, { deliveryMode: "live" }),
      store,
      daemon: new FakeDaemon(),
      delivery: new WindowsDelivery({
        notifyUrl: "http://127.0.0.1:23118/notify", token: "t", timeoutMs: 2000, deliveryMode: "live",
        fetchImpl: async () => ({ status: 200, ok: true, text: async () => "invalid" }),
      }),
      now: () => now,
    });
    serviceInvalid.agentDisplayNames.set(finish.agentKey, "Agent");
    await serviceInvalid.deliverOne(store.getItem(finish.agentKey));
    assert.equal(store.getItem(finish.agentKey).status, "invalid");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

async function waitUntil(predicate, timeoutMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("waitUntil timeout");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
