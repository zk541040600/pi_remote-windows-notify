import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { OwnerRegistry, multiOwnerMetadata } from '../core/owner-registry.mjs';
import { buildTrustedOriginMap } from '../core/url-session.mjs';
import { computeRoutingKeySync } from '../core/routing-key.mjs';
import { MessageTypes, OwnerEvents } from '../core/protocol.mjs';

const INSTANCE = '11111111-2222-3333-4444-555555555555';
const ORIGIN = 'http://10.23.50.137:30141';
const S1 = 'session-alpha-example';
const S2 = 'session-beta-example';

function makeRegistry() {
  /** @type {import('../core/owner-registry.mjs').RouteMessage[]} */
  const sent = [];
  const registry = new OwnerRegistry({
    browserKind: 'chrome',
    profileKey: 'pf_testprofilekey01',
    adapterKey: 'ad_chrome_test_abcdef0123456789',
    trustedOrigins: buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]),
    preferSyncRoutingKey: true,
    send: async (msg) => {
      sent.push(msg);
      return { result: 'ok', requestId: msg.requestId };
    },
  });
  return { registry, sent };
}

describe('owner registry state transitions', () => {
  it('registers owner only for trusted session URL', async () => {
    const { registry, sent } = makeRegistry();
    const r1 = await registry.observeTab({
      tabId: 1,
      windowId: 10,
      url: `${ORIGIN}/`,
    });
    assert.equal(r1.action, 'noop');
    assert.equal(registry.listOwners().length, 0);

    const r2 = await registry.observeTab({
      tabId: 1,
      windowId: 10,
      url: `${ORIGIN}/?session=${S1}`,
    });
    assert.equal(r2.action, 'registered');
    assert.equal(registry.listOwners().length, 1);
    assert.ok(sent.some((m) => m.type === MessageTypes.RegisterOwner));

    const owner = registry.getByTabId(1);
    assert.ok(owner);
    assert.equal(owner.routingKey, computeRoutingKeySync(INSTANCE, S1));
    assert.ok(owner.pageKey.startsWith('pg_'));
    assert.ok(owner.ownerKey.startsWith('ow_'));
  });

  it('atomically unregisters then registers on session change', async () => {
    const { registry, sent } = makeRegistry();
    await registry.observeTab({ tabId: 2, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    const first = registry.getByTabId(2);
    assert.ok(first);
    const firstPage = first.pageKey;

    sent.length = 0;
    const r = await registry.observeTab({
      tabId: 2,
      windowId: 10,
      url: `${ORIGIN}/?session=${S2}`,
    });
    assert.equal(r.action, 'registered');
    const second = registry.getByTabId(2);
    assert.ok(second);
    assert.notEqual(second.pageKey, firstPage);
    assert.equal(second.routingKey, computeRoutingKeySync(INSTANCE, S2));

    const types = sent.map((m) => m.type);
    assert.ok(types.includes(MessageTypes.UnregisterOwner));
    assert.ok(types.includes(MessageTypes.RegisterOwner));
    assert.ok(
      types.indexOf(MessageTypes.UnregisterOwner) < types.indexOf(MessageTypes.RegisterOwner),
    );
  });

  it('unregisters when leaving trusted origin or closing tab', async () => {
    const { registry } = makeRegistry();
    await registry.observeTab({ tabId: 3, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    assert.equal(registry.listOwners().length, 1);

    await registry.observeTab({ tabId: 3, windowId: 10, url: 'https://example.com/' });
    assert.equal(registry.listOwners().length, 0);

    await registry.observeTab({ tabId: 3, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    assert.equal(registry.listOwners().length, 1);
    await registry.removeTab(3);
    assert.equal(registry.listOwners().length, 0);
  });

  it('refreshes lease without new pageKey when same session', async () => {
    const { registry } = makeRegistry();
    await registry.observeTab({ tabId: 4, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    const pageKey = registry.getByTabId(4).pageKey;
    const r = await registry.observeTab({
      tabId: 4,
      windowId: 10,
      url: `${ORIGIN}/?session=${S1}`,
    });
    assert.equal(r.action, 'refreshed');
    assert.equal(registry.getByTabId(4).pageKey, pageKey);
  });

  it('marks only a committed document as explicit-open and restores never steal', async () => {
    const { registry, sent } = makeRegistry();
    await registry.observeTab({
      tabId: 8,
      windowId: 10,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const enumerated = sent.find((m) => m.type === MessageTypes.RegisterOwner);
    assert.equal(enumerated.ownerEvent, OwnerEvents.Restore);
    assert.equal(enumerated.openEventId, undefined);
    const restorePageKey = registry.getByTabId(8).pageKey;

    sent.length = 0;
    await registry.observeTab({
      tabId: 8,
      windowId: 10,
      url: `${ORIGIN}/?session=${S1}`,
      explicitOpen: true,
    });
    const explicit = sent.find((m) => m.type === MessageTypes.RegisterOwner);
    assert.equal(explicit.ownerEvent, OwnerEvents.ExplicitOpen);
    assert.equal(typeof explicit.openEventId, 'string');
    assert.equal(typeof explicit.openedAtMs, 'number');
    assert.notEqual(registry.getByTabId(8).pageKey, restorePageKey);

    sent.length = 0;
    await registry.observeTab({
      tabId: 8,
      windowId: 10,
      url: `${ORIGIN}/?session=${S1}`,
    });
    const reconnect = sent.find((m) => m.type === MessageTypes.RegisterOwner);
    assert.equal(reconnect.ownerEvent, OwnerEvents.Restore);
    assert.equal(reconnect.openEventId, undefined);
    assert.equal(reconnect.openedAtMs, undefined);
  });

  it('tracks multi-owner metadata without picking a winner', async () => {
    const { registry } = makeRegistry();
    await registry.observeTab({ tabId: 5, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    await registry.observeTab({ tabId: 6, windowId: 11, url: `${ORIGIN}/?session=${S1}` });

    const rk = computeRoutingKeySync(INSTANCE, S1);
    const meta = multiOwnerMetadata(registry, INSTANCE, rk);
    assert.equal(meta.count, 2);
    assert.equal(meta.tabIds.sort()[0], 5);
    assert.equal(new Set(meta.pageKeys).size, 2);
    assert.equal(registry.countOwnersForRoute(INSTANCE, rk), 2);
  });

  it('register-owner messages omit raw session and full URL', async () => {
    const { registry, sent } = makeRegistry();
    await registry.observeTab({ tabId: 7, windowId: 10, url: `${ORIGIN}/?session=${S1}` });
    const reg = sent.find((m) => m.type === MessageTypes.RegisterOwner);
    assert.ok(reg);
    const json = JSON.stringify(reg);
    assert.equal(json.includes(S1), false);
    assert.equal(json.includes(ORIGIN), false);
    assert.equal(json.includes('?session='), false);
    assert.equal(typeof reg.routingKey, 'string');
    assert.equal(reg.routingKey.length, 64);
  });
});
