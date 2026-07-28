import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeConfig,
  configToTrustedMap,
  configHostPermissions,
  saveConfig,
  loadConfig,
  emptyConfig,
} from '../core/config.mjs';
import {
  createSafeLogger,
  assertNoSensitiveLogMaterial,
  looksLikeSessionOrUrl,
} from '../core/safe-log.mjs';
import { NATIVE_HOST_NAME } from '../core/protocol.mjs';

describe('config + safe log', () => {
  it('normalizes trusted origins and browser kind', () => {
    const cfg = normalizeConfig(
      {
        browserKind: 'edge',
        trustedOrigins: [
          { origin: 'http://10.23.50.137:30141/extra', instanceKey: '11111111-2222-3333-4444-555555555555' },
          { origin: 'not a url', instanceKey: 'bad' },
        ],
        leaseTtlMs: 999999,
      },
      { browserKind: 'chrome' },
    );
    assert.equal(cfg.browserKind, 'edge');
    assert.equal(cfg.trustedOrigins.length, 1);
    assert.equal(cfg.trustedOrigins[0].origin, 'http://10.23.50.137:30141');
    assert.equal(cfg.leaseTtlMs, 120_000);
    assert.ok(cfg.profileKey.startsWith('pf_'));
  });

  it('round-trips storage', async () => {
    /** @type {Record<string, unknown>} */
    const store = {};
    const storage = {
      get: async (keys) => {
        const out = {};
        for (const k of keys) if (k in store) out[k] = store[k];
        return out;
      },
      set: async (items) => {
        Object.assign(store, items);
      },
    };

    const empty = emptyConfig('chrome');
    empty.trustedOrigins = [
      { origin: 'http://127.0.0.1:30141', instanceKey: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' },
    ];
    await saveConfig(storage, empty);
    const loaded = await loadConfig(storage, { browserKind: 'chrome' });
    assert.equal(loaded.trustedOrigins.length, 1);
    const map = configToTrustedMap(loaded);
    assert.equal(map.get('http://127.0.0.1:30141'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    assert.deepEqual(configHostPermissions(loaded), ['http://127.0.0.1:30141/*']);
  });

  it('safe logger redacts URLs and forbids session fields', () => {
    /** @type {unknown[]} */
    const sink = [];
    const log = createSafeLogger({
      sink: (r) => sink.push(r),
      console: { info() {}, warn() {}, error() {}, debug() {} },
    });
    log.info('test-event', {
      routingFp: 'abc123',
      url: 'http://10.23.50.137:30141/?session=secret',
      sessionId: 'should-drop-by-name',
      tabId: 3,
    });
    assert.equal(sink.length, 1);
    const fields = /** @type {any} */ (sink[0]).fields;
    // Forbidden field names (url/sessionId) are dropped entirely.
    assert.equal('url' in fields, false);
    assert.equal('sessionId' in fields, false);
    assert.equal(fields.tabId, 3);
    assert.equal(fields.routingFp, 'abc123');

    assert.equal(looksLikeSessionOrUrl('http://x'), true);
    assert.equal(looksLikeSessionOrUrl('plain'), false);

    // Logger replaced raw URL with placeholder; scan fields that must stay clean.
    assert.equal(assertNoSensitiveLogMaterial({ routingFp: fields.routingFp, tabId: fields.tabId }).ok, true);
    assert.equal(assertNoSensitiveLogMaterial({ href: 'http://evil' }).ok, false);
    assert.equal(assertNoSensitiveLogMaterial({ sessionId: 'abc' }).ok, false);
  });

  it('exports native host name io.pi.notify.route', () => {
    assert.equal(NATIVE_HOST_NAME, 'io.pi.notify.route');
  });
});
