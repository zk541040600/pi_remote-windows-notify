import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeOrigin,
  buildTrustedOriginMap,
  parseSessionUrl,
  validateSessionId,
  matchTrustedOrigin,
  originToHostPermission,
} from '../core/url-session.mjs';

const INSTANCE = '11111111-2222-3333-4444-555555555555';
const ORIGIN = 'http://10.23.50.137:30141';

describe('URL / session parsing', () => {
  it('normalizes origins without credentials or path', () => {
    const n = normalizeOrigin(`${ORIGIN}/chat?x=1`);
    assert.ok(n);
    assert.equal(n.origin, ORIGIN);
    assert.equal(normalizeOrigin('https://user:pass@evil.example/'), null);
    assert.equal(normalizeOrigin('file:///tmp/x'), null);
  });

  it('builds trusted origin map with port variants', () => {
    const map = buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]);
    assert.equal(map.get(ORIGIN), INSTANCE);
    const m = matchTrustedOrigin(`${ORIGIN}/?session=abc`, map);
    assert.equal(m.matched, true);
    assert.equal(m.instanceKey, INSTANCE);
  });

  it('registers only when session query is valid', () => {
    const map = buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]);

    const ok = parseSessionUrl(`${ORIGIN}/?session=session-alpha-example`, map);
    assert.equal(ok.ok, true);
    if (ok.ok) {
      assert.equal(ok.sessionId, 'session-alpha-example');
      assert.equal(ok.origin, ORIGIN);
    }

    assert.equal(parseSessionUrl(`${ORIGIN}/`, map).ok, false);
    assert.equal(parseSessionUrl(`${ORIGIN}/?session=`, map).ok, false);
    assert.equal(parseSessionUrl('http://evil.example/?session=x', map).ok, false);
    assert.equal(parseSessionUrl(`${ORIGIN}/?session=${'a'.repeat(300)}`, map).ok, false);
  });

  it('decodes session query values', () => {
    const map = buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]);
    const parsed = parseSessionUrl(`${ORIGIN}/?session=hello%2Fworld`, map);
    assert.equal(parsed.ok, true);
    if (parsed.ok) assert.equal(parsed.sessionId, 'hello/world');
  });

  it('rejects control characters in session id', () => {
    assert.equal(validateSessionId('good-id'), 'good-id');
    assert.equal(validateSessionId('bad\nid'), null);
    assert.equal(validateSessionId('http://x'), null);
  });

  it('maps origin to host permission pattern', () => {
    assert.equal(originToHostPermission(ORIGIN), `${ORIGIN}/*`);
  });

  it('ignores fragment-only changes for session extraction', () => {
    const map = buildTrustedOriginMap([{ origin: ORIGIN, instanceKey: INSTANCE }]);
    const a = parseSessionUrl(`${ORIGIN}/?session=s1#frag`, map);
    assert.equal(a.ok, true);
    if (a.ok) assert.equal(a.sessionId, 's1');
  });
});
