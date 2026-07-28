import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  MessageTypes,
  PROTOCOL_VERSION,
  DEFAULT_WAKE_INTERVAL_MS,
  WAKE_MAINTENANCE_INTERVAL_MS,
  DEFAULT_POLL_INTERVAL_MS,
} from '../core/protocol.mjs';
import {
  isWakeMessage,
  validateWakeMessage,
  buildWakeMessage,
  shouldRunWakeMaintenance,
  refreshLiveOwnerLeases,
  dispatchWakeToPoller,
  WAKE_FIELDS,
  WAKE_FORBIDDEN_FIELDS,
} from '../core/wake.mjs';
import {
  ActivationPoller,
  shouldPollTick,
} from '../core/activation-poller.mjs';
import { OwnerRegistry } from '../core/owner-registry.mjs';
import { buildTrustedOriginMap } from '../core/url-session.mjs';
import { RouteResults, RejectReasons } from '../core/protocol.mjs';

describe('wake protocol constants', () => {
  it('exports wake type and interval aligned with 5s activation deadline', () => {
    assert.equal(MessageTypes.Wake, 'wake');
    assert.equal(DEFAULT_WAKE_INTERVAL_MS, 1_000);
    assert.equal(WAKE_MAINTENANCE_INTERVAL_MS, 15_000);
    // Multiple wake opportunities inside DefaultClientWaitMs (5s).
    assert.ok(DEFAULT_WAKE_INTERVAL_MS * 3 < 5_000);
    assert.ok(DEFAULT_POLL_INTERVAL_MS <= 5_000);
  });

  it('buildWakeMessage is versioned and minimal', () => {
    const msg = buildWakeMessage(3);
    assert.deepEqual(msg, {
      protocolVersion: PROTOCOL_VERSION,
      type: MessageTypes.Wake,
      seq: 3,
    });
    assert.deepEqual(Object.keys(msg).sort(), [...WAKE_FIELDS].sort());
    const serialized = JSON.stringify(msg);
    for (const field of WAKE_FORBIDDEN_FIELDS) {
      assert.equal(serialized.includes(field), false, `must not contain ${field}`);
    }
    assert.equal(serialized.includes('http'), false);
    assert.equal(serialized.includes('session'), false);
  });
});

describe('isWakeMessage / validateWakeMessage', () => {
  it('accepts only canonical wake frames', () => {
    assert.equal(isWakeMessage({ type: 'wake', protocolVersion: 1, seq: 1 }), true);
    const ok = validateWakeMessage({ type: 'wake', protocolVersion: 1, seq: 9 });
    assert.equal(ok.ok, true);

    assert.deepEqual(validateWakeMessage({ type: 'wake', seq: 2 }), {
      ok: false,
      reason: 'protocol-mismatch',
    });
    assert.deepEqual(validateWakeMessage({ type: 'wake', protocolVersion: 2, seq: 2 }), {
      ok: false,
      reason: 'protocol-mismatch',
    });
    assert.deepEqual(validateWakeMessage({ type: 'wake', protocolVersion: 1, seq: 0 }), {
      ok: false,
      reason: 'invalid-seq',
    });
    assert.deepEqual(
      validateWakeMessage({ type: 'wake', protocolVersion: 1, seq: 2, note: 'extra' }),
      { ok: false, reason: 'unknown-field:note' },
    );
  });

  it('rejects non-wake and sensitive fields', () => {
    assert.equal(isWakeMessage(null), false);
    assert.equal(isWakeMessage({ type: 'activate' }), false);
    assert.equal(isWakeMessage({ type: 'result' }), false);

    const withRouting = validateWakeMessage({
      type: 'wake',
      protocolVersion: 1,
      seq: 1,
      routingKey: 'a'.repeat(64),
    });
    assert.equal(withRouting.ok, false);
    assert.match(withRouting.reason, /forbidden-field:routingKey/);

    const withUrl = validateWakeMessage({
      type: 'wake',
      protocolVersion: 1,
      seq: 1,
      note: 'http://10.23.50.137:30141/?session=abc',
    });
    assert.equal(withUrl.ok, false);
    assert.match(withUrl.reason, /unknown-field:note/);

    const withSession = validateWakeMessage({
      type: 'wake',
      protocolVersion: 1,
      sessionId: 'raw-session-id-must-not-appear',
    });
    assert.equal(withSession.ok, false);
  });
});

describe('shouldRunWakeMaintenance', () => {
  it('gates maintenance by interval', () => {
    assert.equal(
      shouldRunWakeMaintenance({ lastMaintenanceMs: 1000, nowMs: 1000, intervalMs: 15_000 }),
      false,
    );
    assert.equal(
      shouldRunWakeMaintenance({ lastMaintenanceMs: 1000, nowMs: 16_000, intervalMs: 15_000 }),
      true,
    );
    assert.equal(
      shouldRunWakeMaintenance({ lastMaintenanceMs: 1000, nowMs: 15_999, intervalMs: 15_000 }),
      false,
    );
  });
});

describe('refreshLiveOwnerLeases', () => {
  const instanceKey = '11111111-2222-3333-4444-555555555555';
  const origin = 'http://10.23.50.137:30141';

  function makeRegistry(sent) {
    return new OwnerRegistry({
      browserKind: 'chrome',
      profileKey: 'pf_wake_lease_test',
      adapterKey: 'ad_wake_lease_test',
      trustedOrigins: buildTrustedOriginMap([{ origin, instanceKey }]),
      preferSyncRoutingKey: true,
      send: async (msg) => {
        sent.push(msg);
        return { result: RouteResults.Ok, requestId: msg.requestId };
      },
    });
  }

  it('heartbeats a live current owner without re-registering it', async () => {
    const sent = [];
    const registry = makeRegistry(sent);
    await registry.observeTab({ tabId: 10, windowId: 1, url: `${origin}/?session=live-a` });
    const owner = registry.getByTabId(10);
    sent.length = 0;

    const out = await refreshLiveOwnerLeases({
      registry,
      tabsGet: async () => ({ windowId: 2, url: `${origin}/?session=live-a` }),
      now: () => 1234,
    });

    assert.deepEqual(out, { refreshed: 1, removed: 0, skipped: 0 });
    assert.equal(owner.windowId, 2);
    assert.equal(owner.lastSeenAtMs, 1234);
    assert.deepEqual(sent.map((msg) => msg.type), [MessageTypes.Heartbeat]);
    assert.equal(sent[0].ownerKey, owner.ownerKey);
  });

  it('does not revive an owner replaced while tabs.get is blocked', async () => {
    const sent = [];
    const registry = makeRegistry(sent);
    await registry.observeTab({ tabId: 11, windowId: 1, url: `${origin}/?session=old` });
    const oldOwner = registry.getByTabId(11);
    let releaseTab;
    const tabReady = new Promise((resolve) => {
      releaseTab = resolve;
    });

    const refresh = refreshLiveOwnerLeases({
      registry,
      tabsGet: async () => tabReady,
    });
    await Promise.resolve();

    await registry.observeTab({ tabId: 11, windowId: 1, url: `${origin}/?session=new` });
    const newOwner = registry.getByTabId(11);
    sent.length = 0;
    releaseTab({ windowId: 1, url: `${origin}/?session=old` });

    const out = await refresh;
    assert.deepEqual(out, { refreshed: 0, removed: 0, skipped: 1 });
    assert.notEqual(newOwner.ownerKey, oldOwner.ownerKey);
    assert.equal(registry.getByTabId(11).ownerKey, newOwner.ownerKey);
    assert.equal(sent.some((msg) => msg.type === MessageTypes.Heartbeat), false);
    assert.equal(sent.some((msg) => msg.type === MessageTypes.RegisterOwner), false);
  });

  it('removes a current owner whose live URL changed instead of renewing it', async () => {
    const sent = [];
    const registry = makeRegistry(sent);
    await registry.observeTab({ tabId: 12, windowId: 1, url: `${origin}/?session=before` });
    sent.length = 0;

    const out = await refreshLiveOwnerLeases({
      registry,
      tabsGet: async () => ({ windowId: 1, url: `${origin}/?session=after` }),
    });

    assert.deepEqual(out, { refreshed: 0, removed: 1, skipped: 0 });
    assert.equal(registry.getByTabId(12), undefined);
    assert.deepEqual(sent.map((msg) => msg.type), [MessageTypes.UnregisterOwner]);
  });
});

describe('dispatchWakeToPoller', () => {
  it('forces one poller tick on wake', async () => {
    let ticks = 0;
    const poller = {
      async tick() {
        ticks += 1;
        return { action: 'no-pending' };
      },
    };
    const out = await dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 1 },
      poller,
    );
    assert.equal(ticks, 1);
    assert.equal(out?.action, 'no-pending');
  });

  it('does not double-handle a matched poll response as a wake', async () => {
    let ticks = 0;
    const poller = {
      async tick() {
        ticks += 1;
        return { action: 'no-pending' };
      },
    };
    const out = await dispatchWakeToPoller(
      { type: 'result', requestId: 'poll-response-1', result: 'ok', reason: 'no-pending' },
      poller,
    );
    assert.equal(out, null);
    assert.equal(ticks, 0);
  });

  it('makes invalid or polluted wake frames non-actionable', async () => {
    let ticks = 0;
    const invalidReasons = [];
    const poller = {
      async tick() {
        ticks += 1;
        return { action: 'no-pending' };
      },
    };

    const out = await dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 1, routingKey: 'a'.repeat(64) },
      poller,
      { onInvalid: (reason) => invalidReasons.push(reason) },
    );

    assert.deepEqual(out, { action: 'skipped', reason: 'invalid-wake' });
    assert.equal(ticks, 0);
    assert.deepEqual(invalidReasons, ['forbidden-field:routingKey']);
  });

  it('respects single-flight via existing poller.tick gate', async () => {
    /** @type {(v?: unknown) => void} */
    let release;
    const barrier = new Promise((resolve) => {
      release = resolve;
    });

    /** @type {Record<string, unknown>[]} */
    const sent = [];
    const port = {
      isConnected: true,
      async send(msg) {
        sent.push(msg);
        await barrier;
        return { result: RouteResults.Ok, reason: RejectReasons.NoPending, requestId: msg.requestId };
      },
      post() {},
    };

    const registry = {
      buildPollActivation() {
        return {
          type: MessageTypes.PollActivation,
          requestId: 'wake-sf-poll-1',
          adapterKey: 'ad_test',
          issuedAtMs: 1,
          expiresAtMs: 5001,
          protocolVersion: 1,
        };
      },
    };

    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: {
        tabsGet: async () => null,
        tabsUpdate: async () => null,
        windowsUpdate: async () => null,
        windowsGet: async () => null,
      },
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;

    const first = dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 1 },
      poller,
    );
    await Promise.resolve();
    assert.equal(poller.isInFlight, true);

    // Second wake while in-flight must skip via single-flight gate (not a second activate path).
    const second = await dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 2 },
      poller,
    );
    assert.equal(second?.action, 'skipped');
    assert.equal(second?.reason, 'in-flight');

    release();
    const firstOut = await first;
    assert.equal(firstOut?.action, 'no-pending');
    assert.equal(sent.length, 1);
  });

  it('disconnected poller tick is skipped (fail-closed)', async () => {
    const port = {
      isConnected: false,
      async send() {
        throw new Error('should-not-send');
      },
      post() {},
    };
    const poller = new ActivationPoller({
      getRegistry: () => ({
        buildPollActivation: () => ({ type: MessageTypes.PollActivation, requestId: 'x' }),
      }),
      getPort: () => port,
      browserApi: {
        tabsGet: async () => null,
        tabsUpdate: async () => null,
        windowsUpdate: async () => null,
        windowsGet: async () => null,
      },
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;

    const out = await dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 1 },
      poller,
    );
    assert.equal(out?.action, 'skipped');
    assert.equal(out?.reason, 'disconnected');
    assert.deepEqual(shouldPollTick({ connected: false, inFlight: false, stopped: false }), {
      run: false,
      reason: 'disconnected',
    });
  });

  it('wake with no poller reports skipped', async () => {
    const out = await dispatchWakeToPoller(
      { type: 'wake', protocolVersion: 1, seq: 1 },
      null,
    );
    assert.equal(out?.action, 'skipped');
    assert.equal(out?.reason, 'no-poller');
  });
});
