import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  WindowsDelivery,
  classifyCloseResponse,
  classifyNotifyResponse,
  nextBackoffMs,
  validateHealthSnapshot,
} from "../src/delivery.mjs";
import { HealthLeaseOwner, isLeaseHealthy, LEASE_SCHEMA } from "../src/lease.mjs";
import { DurableStore } from "../src/store.mjs";
import { PaseoSenderService } from "../src/service.mjs";
import { eventFingerprint } from "../src/privacy.mjs";
import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const contract = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../fixtures/windows-paseo-v1-contract.json"),
    "utf8",
  ),
);

test("response classification matrix", () => {
  assert.equal(classifyNotifyResponse(200, "ok"), "ok");
  assert.equal(classifyNotifyResponse(200, "dedup"), "dedup");
  assert.equal(classifyNotifyResponse(200, "suppressed-active-agent"), "suppressed-active-agent");
  assert.equal(classifyNotifyResponse(200, "retry"), "retry");
  assert.equal(classifyNotifyResponse(200, "invalid"), "invalid");
  assert.equal(classifyNotifyResponse(500, "x"), "retry");
  // 401/403 are auth/config failures — not contract-invalid terminalization.
  assert.equal(classifyNotifyResponse(403, "x"), "auth");
  assert.equal(classifyNotifyResponse(401, "x"), "auth");
  assert.equal(classifyCloseResponse(200, "ok"), "ok");
  assert.equal(classifyCloseResponse(200, "invalid"), "invalid");
  assert.equal(classifyCloseResponse(200, "retry"), "retry");
  assert.equal(classifyCloseResponse(403, "x"), "auth");
  assert.equal(classifyCloseResponse(401, "x"), "auth");
});

test("backoff grows with bound and jitter", () => {
  const a0 = nextBackoffMs(0, { initialMs: 1000, maxMs: 60000, random: () => 0.5 });
  const a5 = nextBackoffMs(5, { initialMs: 1000, maxMs: 60000, random: () => 0.5 });
  assert.ok(a5 >= a0);
  assert.ok(a5 <= 60000);
  const maxed = nextBackoffMs(20, { initialMs: 1000, maxMs: 60000, random: () => 0.5 });
  assert.equal(maxed <= 60000, true);
});

test("health snapshot validation matches parent contract", () => {
  const good = contract.health.responseSchema;
  assert.equal(validateHealthSnapshot(good).ok, true);
  assert.equal(validateHealthSnapshot({ ...good, version: 2 }).ok, false);
  assert.equal(
    validateHealthSnapshot({
      ...good,
      capabilities: { notifyV1: true, closeV1: true, existingClickEventV1: false },
    }).ok,
    false,
  );
  assert.equal(validateHealthSnapshot({ version: 1, ready: true }).ok, false);
  assert.equal(validateHealthSnapshot({ ...good, unexpected: true }).ok, false);
  assert.equal(validateHealthSnapshot({ ...good, listenerReady: false }).ok, false);
  assert.equal(validateHealthSnapshot({ ...good, routeReady: false, ready: false }).ok, false);
  assert.equal(validateHealthSnapshot({ ...good, routeState: "unknown-state" }).ok, false);
  assert.equal(
    validateHealthSnapshot({ ...good, capabilities: { ...good.capabilities, extra: true } }).ok,
    false,
  );
});

test("delivery notify posts exact v1 and classifies suppressed", async () => {
  /** @type {any[]} */
  const requests = [];
  const delivery = new WindowsDelivery({
    notifyUrl: "http://127.0.0.1:23118/notify",
    token: "secret-token",
    timeoutMs: 2000,
    deliveryMode: "live",
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      return {
        status: 200,
        ok: true,
        text: async () => "suppressed-active-agent",
      };
    },
  });

  const result = await delivery.notify({
    notificationId: contract.notify.payload.notificationId,
    kind: "finished",
    serverId: "server-1",
    workspaceId: "workspace-1",
    agentId: "agent-1",
    agentDisplayName: "Agent",
  });
  assert.equal(result.code, "suppressed-active-agent");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].options.method, "POST");
  assert.equal(requests[0].options.redirect, "error");
  assert.equal(requests[0].options.headers["X-Pi-Notify-Token"], "secret-token");
  const body = JSON.parse(requests[0].options.body);
  assert.equal(body.originKind, "paseo");
  assert.equal(body.paseoRoute.version, 1);
  assert.equal(body.title.includes("secret"), false);
});

test("close posts exact three-field body", async () => {
  /** @type {any[]} */
  const requests = [];
  const delivery = new WindowsDelivery({
    notifyUrl: "http://127.0.0.1:23118/notify",
    token: "t",
    timeoutMs: 2000,
    deliveryMode: "live",
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      return { status: 200, ok: true, text: async () => "ok" };
    },
  });
  const result = await delivery.close(contract.close.payload.notificationId);
  assert.equal(result.code, "ok");
  assert.match(requests[0].url, /\/paseo\/close$/);
  const body = JSON.parse(requests[0].options.body);
  assert.deepEqual(Object.keys(body).sort(), ["notificationId", "originKind", "version"]);
});

test("health uses POST /paseo/health never GET", async () => {
  /** @type {any[]} */
  const requests = [];
  const delivery = new WindowsDelivery({
    notifyUrl: "http://127.0.0.1:23118/notify",
    token: "t",
    timeoutMs: 2000,
    deliveryMode: "live",
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), method: options.method });
      return {
        status: 200,
        ok: true,
        text: async () => JSON.stringify(contract.health.responseSchema),
      };
    },
  });
  const health = await delivery.probeHealth();
  assert.equal(health.ok, true);
  assert.equal(health.ready, true);
  assert.equal(requests[0].method, "POST");
  assert.match(requests[0].url, /\/paseo\/health$/);
  assert.equal(requests.some((r) => r.method === "GET"), false);
});

test("lease refresh only when daemon + windows ready; stale fails open", async () => {
  const dir = mkdtempSync(join(tmpdir(), "paseo-lease-"));
  try {
    let now = 1_000_000;
    const owner = new HealthLeaseOwner({
      stateDir: dir,
      staleMs: 15_000,
      now: () => now,
    });
    await owner.load();
    assert.equal(owner.isHealthy(), false);

    const skip = await owner.refresh({
      daemonConnected: false,
      serverId: null,
      windowsHealth: { ok: true, ready: true, snapshot: contract.health.responseSchema },
    });
    assert.equal(skip.refreshed, false);

    const ok = await owner.refresh({
      daemonConnected: true,
      serverId: "server-1",
      windowsHealth: { ok: true, ready: true, snapshot: contract.health.responseSchema },
    });
    assert.equal(ok.refreshed, true);
    assert.equal(owner.isHealthy(), true);

    now += 16_000;
    assert.equal(owner.isHealthy(), false);

    // Any future timestamp, even 1ms, fails open.
    assert.equal(
      isLeaseHealthy(
        { schemaVersion: LEASE_SCHEMA, lastHealthyAt: now + 1, status: "healthy" },
        { now, staleMs: 15_000 },
      ),
      false,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("delivery boundary rejects malformed recovered identity without POST", async () => {
  let called = false;
  const delivery = new WindowsDelivery({
    notifyUrl: "http://127.0.0.1:23118/notify",
    token: "t",
    timeoutMs: 2000,
    deliveryMode: "live",
    fetchImpl: async () => {
      called = true;
      return { status: 200, ok: true, text: async () => "ok" };
    },
  });
  const result = await delivery.notify({
    notificationId: "not-a-uuid",
    kind: "finished",
    serverId: "s",
    workspaceId: "w",
    agentId: "a",
  });
  assert.equal(result.code, "invalid");
  assert.equal(called, false);
  assert.equal((await delivery.close("bad-id")).code, "invalid");
  assert.equal(called, false);
});

test("shadow mode does not POST", async () => {
  let called = false;
  const delivery = new WindowsDelivery({
    notifyUrl: "http://127.0.0.1:23118/notify",
    token: "t",
    timeoutMs: 2000,
    deliveryMode: "shadow",
    fetchImpl: async () => {
      called = true;
      return { status: 200, ok: true, text: async () => "ok" };
    },
  });
  const result = await delivery.notify({
    notificationId: contract.notify.payload.notificationId,
    kind: "finished",
    serverId: "s",
    workspaceId: "w",
    agentId: "a",
  });
  assert.equal(result.code, "ok");
  assert.equal(called, false);
});

test("shadow and disabled service never refresh takeover lease; disabled never connects", async () => {
  for (const scenario of ["shadow", "disabled"]) {
    const dir = mkdtempSync(join(tmpdir(), "paseo-service-lease-"));
    try {
      let connects = 0;
      let refreshes = 0;
      const daemon = {
        onAgentAttentionRequired: () => () => {},
        subscribeLifecycle: () => () => {},
        subscribeConnectionStatus: () => () => {},
        connect: async () => { connects += 1; },
        close: async () => {},
        isConnected: () => true,
        getServerId: () => "server-1",
        fetchAllAgents: async () => [],
        fetchAllWorkspaces: async () => [],
      };
      const lease = {
        load: async () => null,
        refresh: async () => { refreshes += 1; return { refreshed: true }; },
        isHealthy: () => false,
      };
      const config = {
        enabled: scenario !== "disabled",
        deliveryMode: "shadow",
        daemonUrl: "ws://127.0.0.1:8787",
        clientId: "test",
        windowsEndpoint: "http://127.0.0.1:23118/notify",
        windowsToken: "token",
        timeoutMs: 1000,
        stateDir: dir,
        healthIntervalMs: 60_000,
        leaseStaleMs: 15_000,
        finishedTtlMs: 30 * 60 * 1000,
        backoffInitialMs: 1000,
        backoffMaxMs: 60_000,
        globalConcurrency: 1,
        detailedSummary: false,
        titleMaxCodePoints: 72,
        bodyMaxCodePoints: 220,
        agentDisplayNameFallback: "Agent",
        configPath: "",
      };
      const service = new PaseoSenderService({
        config,
        daemon,
        lease,
        store: new DurableStore(dir),
      });
      await service.start();
      assert.equal(refreshes, 0);
      assert.equal(connects, scenario === "disabled" ? 0 : 1);
      await service.stop();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("failed initial authority reconciliation cannot refresh a live takeover lease", async () => {
  const dir = mkdtempSync(join(tmpdir(), "paseo-authority-lease-"));
  try {
    let refreshes = 0;
    const service = new PaseoSenderService({
      config: {
        enabled: true,
        deliveryMode: "live",
        daemonUrl: "ws://127.0.0.1:8787",
        clientId: "test",
        windowsEndpoint: "http://127.0.0.1:23118/notify",
        windowsToken: "token",
        timeoutMs: 1000,
        stateDir: dir,
        healthIntervalMs: 60_000,
        leaseStaleMs: 15_000,
        finishedTtlMs: 30 * 60 * 1000,
        backoffInitialMs: 1000,
        backoffMaxMs: 60_000,
        globalConcurrency: 1,
        detailedSummary: false,
        titleMaxCodePoints: 72,
        bodyMaxCodePoints: 220,
        agentDisplayNameFallback: "Agent",
        configPath: "",
      },
      daemon: {
        onAgentAttentionRequired: () => () => {},
        subscribeLifecycle: () => () => {},
        subscribeConnectionStatus: () => () => {},
        connect: async () => {},
        close: async () => {},
        isConnected: () => true,
        getServerId: () => "server-1",
        fetchAllAgents: async () => { throw new Error("authority offline"); },
        fetchAllWorkspaces: async () => [],
      },
      delivery: {
        probeHealth: async () => ({ ok: true, ready: true, snapshot: contract.health.responseSchema }),
        abortAll() {},
      },
      lease: {
        load: async () => null,
        refresh: async () => { refreshes += 1; return { refreshed: true }; },
        isHealthy: () => false,
      },
      store: new DurableStore(dir),
    });
    await service.start();
    assert.equal(service.authorityReady, false);
    assert.equal(refreshes, 0);
    await service.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("persisted unresolved attention at startup blocks an otherwise healthy live lease", async () => {
  const dir = mkdtempSync(join(tmpdir(), "paseo-pending-lease-"));
  try {
    const store = new DurableStore(dir);
    await store.load();
    const timestamp = "2026-08-06T12:00:00.000Z";
    const eventFp = eventFingerprint({ serverId: "server-1", agentId: "agent-1", reason: "finished", timestamp });
    await store.transaction(() => store.recordPendingAttention({
      eventFp,
      serverId: "server-1",
      agentId: "agent-1",
      reason: "finished",
      timestamp,
      eventMs: Date.parse(timestamp),
    }));
    let refreshes = 0;
    const config = {
      enabled: true, deliveryMode: "live", daemonUrl: "ws://127.0.0.1:8787", clientId: "test",
      windowsEndpoint: "http://127.0.0.1:23118/notify", windowsToken: "token", timeoutMs: 1000,
      stateDir: dir, healthIntervalMs: 60_000, leaseStaleMs: 15_000, finishedTtlMs: 1_800_000,
      backoffInitialMs: 1000, backoffMaxMs: 60_000, globalConcurrency: 1, detailedSummary: false,
      titleMaxCodePoints: 72, bodyMaxCodePoints: 220, agentDisplayNameFallback: "Agent", configPath: "",
    };
    const service = new PaseoSenderService({
      config,
      store,
      daemon: {
        onAgentAttentionRequired: () => () => {}, subscribeLifecycle: () => () => {}, subscribeConnectionStatus: () => () => {},
        connect: async () => {}, close: async () => {}, isConnected: () => true, getServerId: () => "server-1",
        fetchAllAgents: async () => [{ id: "agent-1", workspaceId: "ws-1", pendingPermissions: [] }],
        fetchAllWorkspaces: async () => [{ id: "ws-1" }],
        fetchAgent: async () => { throw new Error("still unresolved"); },
      },
      delivery: { probeHealth: async () => ({ ok: true, ready: true, snapshot: contract.health.responseSchema }), abortAll() {} },
      lease: { load: async () => null, refresh: async () => { refreshes += 1; }, isHealthy: () => false },
    });
    await service.start();
    assert.equal(service.authorityReady, true);
    assert.equal(service.store.listPendingAuthority().length, 1);
    assert.equal(refreshes, 0);
    await service.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("graceful stop uses monotonic wall bound, not injected service clock", async () => {
  const dir = mkdtempSync(join(tmpdir(), "paseo-stop-"));
  try {
    const service = new PaseoSenderService({
      config: {
        enabled: false,
        deliveryMode: "shadow",
        daemonUrl: "ws://127.0.0.1:8787",
        clientId: "test",
        windowsEndpoint: "http://127.0.0.1:23118/notify",
        windowsToken: "",
        timeoutMs: 1000,
        stateDir: dir,
        healthIntervalMs: 60_000,
        leaseStaleMs: 15_000,
        finishedTtlMs: 30 * 60 * 1000,
        backoffInitialMs: 1000,
        backoffMaxMs: 60_000,
        globalConcurrency: 1,
        detailedSummary: false,
        titleMaxCodePoints: 72,
        bodyMaxCodePoints: 220,
        agentDisplayNameFallback: "Agent",
        configPath: "",
      },
      now: () => 1,
      stopWaitMs: 30,
      daemon: { close: async () => {}, isConnected: () => false, getServerId: () => null },
    });
    service.globalInFlight = 1;
    const started = Date.now();
    const first = service.stop();
    const second = service.stop();
    assert.equal(first, second);
    await first;
    assert.ok(Date.now() - started < 500);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
