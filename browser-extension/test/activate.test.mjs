import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { OwnerRegistry } from '../core/owner-registry.mjs';
import { handleActivateCommand, parseActivateCommand } from '../core/activate.mjs';
import { buildTrustedOriginMap } from '../core/url-session.mjs';
import { computeRoutingKeySync } from '../core/routing-key.mjs';
import { RouteResults, RejectReasons } from '../core/protocol.mjs';

const INSTANCE = '11111111-2222-3333-4444-555555555555';
const ORIGIN = 'http://10.23.50.137:30141';
const S1 = 'session-alpha-example';
const S2 = 'session-beta-example';

function makeRegistry(sent = []) {
  return new OwnerRegistry({
    browserKind: 'edge',
    profileKey: 'pf_edgeprofilekey001',
    adapterKey: 'ad_edge_test_abcdef0123456789ab',
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
 * @param {Map<number, { id: number, focused?: boolean }>} [windows]
 */
function fakeBrowser(tabs, windows = new Map()) {
  return {
    tabsGet: async (tabId) => tabs.get(tabId),
    tabsUpdate: async (tabId, props) => {
      const t = tabs.get(tabId);
      if (!t) throw new Error('missing-tab');
      if (props.active) t.active = true;
      return t;
    },
    windowsUpdate: async (windowId, props) => {
      let w = windows.get(windowId);
      if (!w) {
        w = { id: windowId, focused: false };
        windows.set(windowId, w);
      }
      if (props.focused) w.focused = true;
      return w;
    },
    windowsGet: async (windowId) => windows.get(windowId) ?? { id: windowId, focused: false },
  };
}

describe('activation validation', () => {
  it('confirms session-url when pageKey/routingKey/url still match', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 1,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(1);
    assert.ok(owner);

    const tabs = new Map([
      [1, { id: 1, windowId: 9, url: `${ORIGIN}/?session=${S1}`, active: false }],
    ]);
    const outcome = await handleActivateCommand({
      registry,
      browserApi: fakeBrowser(tabs),
      command: {
        requestId: 'req12345678',
        pageKey: owner.pageKey,
        ownerKey: owner.ownerKey,
        instanceKey: INSTANCE,
        routingKey: owner.routingKey,
      },
    });

    assert.equal(outcome.result, RouteResults.SessionUrlConfirmed);
    assert.equal(tabs.get(1).active, true);
  });

  it('returns stale when live URL session changed', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 2,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(2);
    assert.ok(owner);

    // Simulate navigation without observeTab (race): live tab already on S2
    const tabs = new Map([
      [2, { id: 2, windowId: 9, url: `${ORIGIN}/?session=${S2}`, active: true }],
    ]);
    const outcome = await handleActivateCommand({
      registry,
      browserApi: fakeBrowser(tabs),
      command: {
        requestId: 'reqstale0001',
        pageKey: owner.pageKey,
        instanceKey: INSTANCE,
        routingKey: owner.routingKey,
      },
    });

    assert.equal(outcome.result, RouteResults.Stale);
    assert.ok(outcome.reason);
  });

  it('returns stale for unknown pageKey', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 3,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(3);
    const tabs = new Map([
      [3, { id: 3, windowId: 9, url: `${ORIGIN}/?session=${S1}` }],
    ]);
    const outcome = await handleActivateCommand({
      registry,
      browserApi: fakeBrowser(tabs),
      command: {
        requestId: 'reqmissing01',
        pageKey: 'pg_deadbeefdeadbeefdeadbeefdeadbeef',
        instanceKey: INSTANCE,
        routingKey: owner.routingKey,
      },
    });
    assert.equal(outcome.result, RouteResults.Stale);
    assert.equal(outcome.reason, RejectReasons.TabMissing);
  });

  it('returns stale when routingKey mismatches', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 4,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(4);
    const tabs = new Map([
      [4, { id: 4, windowId: 9, url: `${ORIGIN}/?session=${S1}` }],
    ]);
    const outcome = await handleActivateCommand({
      registry,
      browserApi: fakeBrowser(tabs),
      command: {
        requestId: 'reqmismatch1',
        pageKey: owner.pageKey,
        instanceKey: INSTANCE,
        routingKey: computeRoutingKeySync(INSTANCE, S2),
      },
    });
    assert.equal(outcome.result, RouteResults.Stale);
    assert.equal(outcome.reason, RejectReasons.RoutingKeyMismatch);
  });

  it('returns stale when tab is gone', async () => {
    const registry = makeRegistry();
    await registry.observeTab({
      tabId: 5,
      windowId: 9,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const owner = registry.getByTabId(5);
    const outcome = await handleActivateCommand({
      registry,
      browserApi: fakeBrowser(new Map()),
      command: {
        requestId: 'reqgone00001',
        pageKey: owner.pageKey,
        ownerKey: owner.ownerKey,
        instanceKey: INSTANCE,
        routingKey: owner.routingKey,
      },
    });
    assert.equal(outcome.result, RouteResults.Stale);
    assert.equal(registry.getByTabId(5), undefined);
  });

  it('parseActivateCommand requires required fields', () => {
    assert.equal(parseActivateCommand(null), null);
    assert.equal(parseActivateCommand({ type: 'activate' }), null);
    const ok = parseActivateCommand({
      type: 'activate',
      requestId: 'r'.repeat(16),
      pageKey: 'pg_x',
      instanceKey: INSTANCE,
      routingKey: 'a'.repeat(64),
    });
    assert.ok(ok);
    assert.equal(ok.pageKey, 'pg_x');
  });
});
