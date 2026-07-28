import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { OwnerRegistry } from '../core/owner-registry.mjs';
import {
  ActivationPoller,
  shouldPollTick,
  clampPollIntervalMs,
  buildPollActivationMessage,
  activationDedupKey,
} from '../core/activation-poller.mjs';
import {
  parsePollActivationResponse,
  parseActivateCommand,
  isNoPendingPollResult,
} from '../core/activate.mjs';
import { buildTrustedOriginMap } from '../core/url-session.mjs';
import {
  MessageTypes,
  RouteResults,
  RejectReasons,
  DEFAULT_POLL_INTERVAL_MS,
  MIN_POLL_INTERVAL_MS,
  MAX_POLL_INTERVAL_MS,
} from '../core/protocol.mjs';

const INSTANCE = '11111111-2222-3333-4444-555555555555';
const ORIGIN = 'http://10.23.50.137:30141';
const S1 = 'session-poll-alpha';
const ADAPTER = 'ad_chrome_test_abcdef0123456789ab';

function makeRegistry(sent = []) {
  return new OwnerRegistry({
    browserKind: 'chrome',
    profileKey: 'pf_chromeprofilekey001',
    adapterKey: ADAPTER,
    trustedOrigins: buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]),
    preferSyncRoutingKey: true,
    send: async (msg) => {
      sent.push(msg);
      return { result: 'ok' };
    },
  });
}

/**
 * @param {Map<number, { id: number, windowId: number, url: string, active?: boolean }>} tabs
 */
function fakeBrowser(tabs) {
  return {
    tabsGet: async (tabId) => tabs.get(tabId),
    tabsUpdate: async (tabId, props) => {
      const t = tabs.get(tabId);
      if (!t) throw new Error('missing-tab');
      if (props.active) t.active = true;
      return t;
    },
    windowsUpdate: async (windowId, props) => ({ id: windowId, focused: props.focused === true }),
    windowsGet: async (windowId) => ({ id: windowId, focused: false }),
  };
}

/**
 * @param {{ responses?: unknown[], connected?: boolean }} [opts]
 */
function fakePort(opts = {}) {
  /** @type {unknown[]} */
  const responses = [...(opts.responses || [])];
  /** @type {Record<string, unknown>[]} */
  const sent = [];
  /** @type {Record<string, unknown>[]} */
  const posted = [];
  let connected = opts.connected !== false;

  return {
    sent,
    posted,
    get isConnected() {
      return connected;
    },
    setConnected(v) {
      connected = v;
    },
    async send(msg) {
      sent.push(/** @type {Record<string, unknown>} */ (msg));
      if (!connected) throw new Error('native-port-disconnected');
      if (responses.length === 0) {
        return { result: RouteResults.Ok, reason: RejectReasons.NoPending, requestId: msg.requestId };
      }
      const next = responses.shift();
      if (typeof next === 'function') {
        return next(msg);
      }
      return next;
    },
    post(msg) {
      posted.push(/** @type {Record<string, unknown>} */ (msg));
      if (!connected) throw new Error('native-port-disconnected');
    },
  };
}

describe('protocol constants for poll-activation', () => {
  it('exports PollActivation / ActivationStatus / NoPending / Pending', () => {
    assert.equal(MessageTypes.PollActivation, 'poll-activation');
    assert.equal(MessageTypes.ActivationStatus, 'activation-status');
    assert.equal(MessageTypes.ActivateResult, 'activate-result');
    assert.equal(RouteResults.Pending, 'pending');
    assert.equal(RejectReasons.NoPending, 'no-pending');
    assert.equal(RejectReasons.PendingAdapterDelivery, 'pending-adapter-delivery');
  });

  it('clamps poll interval', () => {
    assert.equal(clampPollIntervalMs(undefined), DEFAULT_POLL_INTERVAL_MS);
    assert.equal(clampPollIntervalMs(10), MIN_POLL_INTERVAL_MS);
    assert.equal(clampPollIntervalMs(999_999), MAX_POLL_INTERVAL_MS);
    assert.equal(clampPollIntervalMs(1500), 1500);
  });
});

describe('parsePollActivationResponse', () => {
  it('treats ok/no-pending as no-op', () => {
    const parsed = parsePollActivationResponse({
      requestId: 'req1',
      result: RouteResults.Ok,
      reason: RejectReasons.NoPending,
    });
    assert.equal(parsed?.kind, 'no-pending');
    assert.equal(isNoPendingPollResult({ result: 'ok', reason: 'no-pending' }), true);
  });

  it('parses ready delivery into ActivateCommand with activationRequestId', () => {
    const raw = {
      requestId: 'poll-req-001',
      result: RouteResults.Ready,
      activationRequestId: 'act-req-aaaaaaaa',
      notificationId: 'notif-bbbbbbbb',
      snapshotId: 'snap-cccccccc',
      ownerKey: 'ow_dddddddddddddddddddddddddddddddd',
      pageKey: 'pg_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      instanceKey: INSTANCE,
      routingKey: 'a'.repeat(64),
      pageFingerprint: 'fp-poll-1',
      deadlineMs: Date.now() + 5_000,
    };
    const parsed = parsePollActivationResponse(raw);
    assert.equal(parsed?.kind, 'ready');
    if (parsed?.kind !== 'ready') return;
    assert.equal(parsed.command.activationRequestId, 'act-req-aaaaaaaa');
    assert.equal(parsed.command.requestId, 'act-req-aaaaaaaa');
    assert.equal(parsed.command.pageKey, raw.pageKey);
    assert.equal(parsed.command.snapshotId, 'snap-cccccccc');
    assert.equal(parsed.command.pageFingerprint, 'fp-poll-1');
  });

  it('fail-closes on adapter-unavailable', () => {
    const parsed = parsePollActivationResponse({
      requestId: 'x',
      result: RouteResults.AdapterUnavailable,
      reason: RejectReasons.AdapterUnknown,
    });
    assert.equal(parsed?.kind, 'error');
    if (parsed?.kind !== 'error') return;
    assert.equal(parsed.result, RouteResults.AdapterUnavailable);
  });

  it('parseActivateCommand accepts poll-ready envelope', () => {
    const cmd = parseActivateCommand({
      result: RouteResults.Ready,
      activationRequestId: 'act-xyz-0001',
      pageKey: 'pg_x',
      instanceKey: INSTANCE,
      routingKey: 'b'.repeat(64),
    });
    assert.ok(cmd);
    assert.equal(cmd.activationRequestId, 'act-xyz-0001');
  });
});

describe('ActivationPoller', () => {
  it('no-pending is a no-op (no activate-result)', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 1,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const port = fakePort({
      responses: [{ result: RouteResults.Ok, reason: RejectReasons.NoPending, requestId: 'p1' }],
    });
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(new Map([[1, { id: 1, windowId: 9, url: `${ORIGIN}/?session=${S1}` }]])),
      intervalMs: 1000,
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;
    const out = await poller.tick();
    assert.equal(out.action, 'no-pending');
    assert.equal(port.posted.length, 0);
    assert.equal(port.sent.length, 1);
    assert.equal(port.sent[0].type, MessageTypes.PollActivation);
    assert.equal(port.sent[0].adapterKey, ADAPTER);
  });

  it('ready delivery runs focus and posts activate-result with activationRequestId', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 2,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(2);
    assert.ok(owner);

    const activationRequestId = 'act-ready-001234567890';
    const port = fakePort({
      responses: [
        {
          requestId: 'poll-1',
          result: RouteResults.Ready,
          activationRequestId,
          notificationId: 'notif-ready-01',
          snapshotId: 'snap-ready-01',
          ownerKey: owner.ownerKey,
          pageKey: owner.pageKey,
          instanceKey: INSTANCE,
          routingKey: owner.routingKey,
          pageFingerprint: owner.pageFingerprint,
          deadlineMs: Date.now() + 10_000,
        },
      ],
    });

    const tabs = new Map([
      [2, { id: 2, windowId: 9, url: `${ORIGIN}/?session=${S1}`, active: false }],
    ]);
    /** @type {Array<Record<string, unknown>>} */
    const completes = [];
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(tabs),
      intervalMs: 1000,
      schedule: () => 1,
      clearSchedule: () => {},
      onActivateComplete: (o) => completes.push(o),
    });
    poller.stopped = false;

    const out = await poller.tick();
    assert.equal(out.action, 'activated');
    assert.equal(out.result, RouteResults.SessionUrlConfirmed);
    assert.equal(out.activationRequestId, activationRequestId);
    assert.equal(tabs.get(2)?.active, true);

    assert.equal(port.posted.length, 1);
    const resultMsg = port.posted[0];
    assert.equal(resultMsg.type, MessageTypes.ActivateResult);
    assert.equal(resultMsg.activationRequestId, activationRequestId);
    assert.equal(resultMsg.result, RouteResults.SessionUrlConfirmed);
    assert.equal(resultMsg.adapterKey, ADAPTER);
    // Must not leak raw session / full URL
    const serialized = JSON.stringify(resultMsg);
    assert.equal(serialized.includes(S1), false);
    assert.equal(serialized.includes(ORIGIN), false);

    assert.equal(completes.length, 1);
    assert.equal(completes[0].activationRequestId, activationRequestId);
  });

  it('final result correlation uses activationRequestId (not poll requestId)', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 3,
      windowId: 1,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(3);
    const activationRequestId = 'act-corr-9999';
    const port = fakePort({
      responses: [
        {
          requestId: 'poll-envelope-id-should-not-be-result-key',
          result: RouteResults.Ready,
          activationRequestId,
          ownerKey: owner.ownerKey,
          pageKey: owner.pageKey,
          instanceKey: INSTANCE,
          routingKey: owner.routingKey,
          snapshotId: 'snap-c',
        },
      ],
    });
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(
        new Map([[3, { id: 3, windowId: 1, url: `${ORIGIN}/?session=${S1}` }]]),
      ),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;
    await poller.tick();
    assert.equal(port.posted[0].activationRequestId, activationRequestId);
    assert.notEqual(port.posted[0].activationRequestId, 'poll-envelope-id-should-not-be-result-key');
  });

  it('pauses while disconnected (no poll send)', async () => {
    const registry = makeRegistry();
    const port = fakePort({ connected: false, responses: [] });
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(new Map()),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;
    const out = await poller.tick();
    assert.equal(out.action, 'skipped');
    assert.equal(out.reason, 'disconnected');
    assert.equal(port.sent.length, 0);
  });

  it('reconnect: after connect, poll runs again', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 4,
      windowId: 1,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(4);
    const port = fakePort({
      connected: false,
      responses: [
        {
          result: RouteResults.Ready,
          activationRequestId: 'act-reconn-01',
          ownerKey: owner.ownerKey,
          pageKey: owner.pageKey,
          instanceKey: INSTANCE,
          routingKey: owner.routingKey,
        },
      ],
    });
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(
        new Map([[4, { id: 4, windowId: 1, url: `${ORIGIN}/?session=${S1}` }]]),
      ),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;

    const skipped = await poller.tick();
    assert.equal(skipped.action, 'skipped');

    port.setConnected(true);
    const out = await poller.tick();
    assert.equal(out.action, 'activated');
    assert.equal(out.activationRequestId, 'act-reconn-01');
  });

  it('single-flight: overlapping tick is skipped', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 5,
      windowId: 1,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(5);

    /** @type {(v: unknown) => void} */
    let release;
    const barrier = new Promise((resolve) => {
      release = resolve;
    });

    const port = fakePort({
      responses: [
        async () => {
          await barrier;
          return {
            result: RouteResults.Ready,
            activationRequestId: 'act-sf-01',
            ownerKey: owner.ownerKey,
            pageKey: owner.pageKey,
            instanceKey: INSTANCE,
            routingKey: owner.routingKey,
          };
        },
      ],
    });

    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(
        new Map([[5, { id: 5, windowId: 1, url: `${ORIGIN}/?session=${S1}` }]]),
      ),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;

    const firstPromise = poller.tick();
    // Allow first tick to enter inFlight
    await Promise.resolve();
    assert.equal(poller.isInFlight, true);

    const second = await poller.tick();
    assert.equal(second.action, 'skipped');
    assert.equal(second.reason, 'in-flight');

    release(undefined);
    const first = await firstPromise;
    assert.equal(first.action, 'activated');
  });

  it('duplicate poll delivery of same activationRequestId is fail-closed (no re-focus)', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 6,
      windowId: 1,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(6);
    const ready = {
      result: RouteResults.Ready,
      activationRequestId: 'act-dup-01',
      ownerKey: owner.ownerKey,
      pageKey: owner.pageKey,
      instanceKey: INSTANCE,
      routingKey: owner.routingKey,
      snapshotId: 'snap-dup',
    };
    const port = fakePort({ responses: [ready, { ...ready }] });
    const tabs = new Map([[6, { id: 6, windowId: 1, url: `${ORIGIN}/?session=${S1}`, active: false }]]);
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(tabs),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;

    const first = await poller.tick();
    assert.equal(first.action, 'activated');
    assert.equal(first.result, RouteResults.SessionUrlConfirmed);

    // Reset active to detect re-focus
    tabs.get(6).active = false;
    const second = await poller.tick();
    assert.equal(second.action, 'duplicate');
    assert.equal(second.result, RouteResults.Rejected);
    assert.equal(second.reason, RejectReasons.Replay);
    // Tab must not be re-focused on duplicate
    assert.equal(tabs.get(6).active, false);
    assert.equal(port.posted.length, 2);
    assert.equal(port.posted[1].activationRequestId, 'act-dup-01');
    assert.equal(port.posted[1].result, RouteResults.Rejected);
  });

  it('stale owner yields activate-result with activationRequestId', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 7,
      windowId: 1,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(7);
    const port = fakePort({
      responses: [
        {
          result: RouteResults.Ready,
          activationRequestId: 'act-stale-01',
          ownerKey: owner.ownerKey,
          pageKey: 'pg_deadbeefdeadbeefdeadbeefdeadbeef',
          instanceKey: INSTANCE,
          routingKey: owner.routingKey,
        },
      ],
    });
    const poller = new ActivationPoller({
      getRegistry: () => registry,
      getPort: () => port,
      browserApi: fakeBrowser(
        new Map([[7, { id: 7, windowId: 1, url: `${ORIGIN}/?session=${S1}` }]]),
      ),
      schedule: () => 1,
      clearSchedule: () => {},
    });
    poller.stopped = false;
    const out = await poller.tick();
    assert.equal(out.action, 'activated');
    assert.equal(out.result, RouteResults.Stale);
    assert.equal(port.posted[0].activationRequestId, 'act-stale-01');
    assert.equal(port.posted[0].result, RouteResults.Stale);
  });

  it('shouldPollTick gate matrix', () => {
    assert.deepEqual(shouldPollTick({ connected: true, inFlight: false, stopped: false }), {
      run: true,
    });
    assert.equal(shouldPollTick({ connected: false, inFlight: false, stopped: false }).run, false);
    assert.equal(shouldPollTick({ connected: true, inFlight: true, stopped: false }).reason, 'in-flight');
    assert.equal(shouldPollTick({ connected: true, inFlight: false, stopped: true }).reason, 'stopped');
  });

  it('buildPollActivationMessage includes adapterKey and type', () => {
    const msg = buildPollActivationMessage({
      adapterKey: ADAPTER,
      requestId: 'reqpoll0001',
      leaseTtlMs: 30_000,
      now: 1_700_000_000_000,
    });
    assert.equal(msg.type, MessageTypes.PollActivation);
    assert.equal(msg.adapterKey, ADAPTER);
    assert.equal(msg.requestId, 'reqpoll0001');
  });

  it('activationDedupKey prefers activationRequestId', () => {
    assert.equal(
      activationDedupKey({
        requestId: 'r1',
        activationRequestId: 'a1',
        pageKey: 'p',
        instanceKey: 'i',
        routingKey: 'k',
      }),
      'a1',
    );
  });

  it('buildActivateResult includes activationRequestId for daemon status', () => {
    const registry = makeRegistry();
    const msg = registry.buildActivateResult({
      activationRequestId: 'act-build-01',
      result: RouteResults.SessionUrlConfirmed,
      snapshotId: 'snap-1',
      elapsedMs: 5,
    });
    assert.equal(msg.type, MessageTypes.ActivateResult);
    assert.equal(msg.activationRequestId, 'act-build-01');
    assert.equal(msg.result, RouteResults.SessionUrlConfirmed);
    assert.equal(msg.adapterKey, ADAPTER);
  });
});
