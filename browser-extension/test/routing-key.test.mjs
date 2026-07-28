import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  computeRoutingKey,
  computeRoutingKeySync,
  fingerprintRoutingKey,
  fingerprintInstanceSync,
} from '../core/routing-key.mjs';
import { ROUTING_KEY_DOMAIN } from '../core/protocol.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

describe('routingKey algorithm', () => {
  it('matches known vectors (domain NUL separators)', async () => {
    const basic = computeRoutingKeySync(
      '11111111-2222-3333-4444-555555555555',
      'session-alpha-example',
    );
    assert.equal(basic.length, 64);
    assert.equal(basic, basic.toLowerCase());
    assert.equal(
      basic,
      '8d36f5af4df10f41530341113539bd96e3e9cd5f31db427630a4e6e4915a88c6',
    );

    const asyncBasic = await computeRoutingKey(
      '11111111-2222-3333-4444-555555555555',
      'session-alpha-example',
    );
    assert.equal(asyncBasic, basic);
  });

  it('is stable for same inputs', () => {
    const a = computeRoutingKeySync('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'stable-session');
    const b = computeRoutingKeySync('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'stable-session');
    assert.equal(a, b);
    assert.equal(a, '981c588f3c44b20b1f42da56b1545edff7e32820095b6ef3e90ef9ffccb41c1f');
  });

  it('differs across sessions and instances', () => {
    const inst = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    assert.notEqual(
      computeRoutingKeySync(inst, 'sess-one'),
      computeRoutingKeySync(inst, 'sess-two'),
    );
    assert.notEqual(
      computeRoutingKeySync('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'same-session-id'),
      computeRoutingKeySync('ffffffff-0000-1111-2222-333333333333', 'same-session-id'),
    );
  });

  it('NUL separators prevent concatenation collisions', () => {
    const k1 = computeRoutingKeySync('a', 'bc');
    const k2 = computeRoutingKeySync('ab', 'c');
    assert.notEqual(k1, k2);
  });

  it('rejects empty fields', () => {
    assert.throws(() => computeRoutingKeySync('', 's'));
    assert.throws(() => computeRoutingKeySync('i', ''));
    assert.throws(() => computeRoutingKeySync('   ', 's'));
  });

  it('fingerprint is first 12 hex chars', () => {
    const key = computeRoutingKeySync('inst-key-001', 'sess-001');
    assert.equal(fingerprintRoutingKey(key), key.slice(0, 12));
    assert.equal(fingerprintInstanceSync('hello-instance').length, 12);
  });

  it('domain constant matches Route Host', () => {
    assert.equal(ROUTING_KEY_DOMAIN, 'pi-web-route-v1');
  });

  it('aligns with route-host fixture file shape when present', () => {
    const fixturePath = join(
      __dirname,
      '../../windows/route-host/fixtures/routing-key-vectors.json',
    );
    try {
      const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
      assert.equal(fixture.domain, 'pi-web-route-v1');
      assert.equal(fixture.algorithm, 'SHA-256');
      for (const v of fixture.vectors) {
        if (v.expectError) {
          assert.throws(() => computeRoutingKeySync(v.instanceKey, v.rawSessionId || 'x'));
          continue;
        }
        if (v.routingKeyPeerSession) {
          const a = computeRoutingKeySync(v.instanceKey, v.rawSessionId);
          const b = computeRoutingKeySync(v.instanceKey, v.routingKeyPeerSession);
          assert.notEqual(a, b);
        }
        if (v.instanceKeyPeer) {
          const a = computeRoutingKeySync(v.instanceKey, v.rawSessionId);
          const b = computeRoutingKeySync(v.instanceKeyPeer, v.rawSessionId);
          assert.notEqual(a, b);
        }
      }
    } catch (err) {
      if (err && err.code === 'ENOENT') {
        // Fixture may be absent in isolated checkout; vectors above still cover algorithm.
        return;
      }
      throw err;
    }
  });
});
