/**
 * Trusted-origin URL parsing for Pi Web session owners.
 * Only registers when URL is an allowed origin AND has a valid ?session= query.
 * Does not inject page scripts; URL is the sole session signal (external-only contract).
 */

import { SESSION_ID_MAX_LENGTH, SESSION_ID_MIN_LENGTH } from './protocol.mjs';

/**
 * @typedef {{ scheme: string, host: string, port: string, origin: string }} NormalizedOrigin
 * @typedef {{ ok: true, origin: string, sessionId: string, pathname: string } | { ok: false, reason: string }} SessionUrlParse
 */

/**
 * Normalize an origin or full URL to scheme://host[:port] (no path/query/fragment/credentials).
 * @param {string} input
 * @returns {NormalizedOrigin | null}
 */
export function normalizeOrigin(input) {
  if (typeof input !== 'string' || input.trim() === '') {
    return null;
  }

  let url;
  try {
    // Allow bare origins without path.
    url = new URL(input.includes('://') ? input : `https://${input}`);
  } catch {
    return null;
  }

  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return null;
  }

  if (url.username || url.password) {
    return null;
  }

  const scheme = url.protocol.slice(0, -1); // strip trailing ':'
  const host = url.hostname.toLowerCase();
  if (!host) {
    return null;
  }

  // Explicit port or default empty for standard ports.
  let port = url.port;
  if (!port) {
    port = scheme === 'https' ? '443' : '80';
  }

  // Origin form used for allowlist compare: always include port for non-default,
  // but also produce a canonical form with explicit port always for map keys.
  const defaultPort = scheme === 'https' ? '443' : '80';
  const origin =
    port === defaultPort
      ? `${scheme}://${host}`
      : `${scheme}://${host}:${port}`;

  return { scheme, host, port, origin };
}

/**
 * Build allowlist map: normalized origin string -> instanceKey.
 * @param {Array<{ origin: string, instanceKey: string }> | Record<string, string>} config
 * @returns {Map<string, string>}
 */
export function buildTrustedOriginMap(config) {
  const map = new Map();
  if (!config) return map;

  const entries = Array.isArray(config)
    ? config.map((e) => [e.origin, e.instanceKey])
    : Object.entries(config);

  for (const [originRaw, instanceKey] of entries) {
    if (typeof instanceKey !== 'string' || instanceKey.trim() === '') continue;
    const norm = normalizeOrigin(originRaw);
    if (!norm) continue;
    map.set(norm.origin, instanceKey.trim());
    // Also index with explicit default port so http://host:80 matches.
    const withPort = `${norm.scheme}://${norm.host}:${norm.port}`;
    map.set(withPort, instanceKey.trim());
  }

  return map;
}

/**
 * Resolve instanceKey for a page URL against trusted origins.
 * @param {string} pageUrl
 * @param {Map<string, string>} trustedMap
 * @returns {{ matched: true, origin: string, instanceKey: string } | { matched: false, reason: string }}
 */
export function matchTrustedOrigin(pageUrl, trustedMap) {
  const norm = normalizeOrigin(pageUrl);
  if (!norm) {
    return { matched: false, reason: 'invalid-url' };
  }

  const keyExact = norm.origin;
  const keyPort = `${norm.scheme}://${norm.host}:${norm.port}`;

  if (trustedMap.has(keyExact)) {
    return { matched: true, origin: keyExact, instanceKey: /** @type {string} */ (trustedMap.get(keyExact)) };
  }
  if (trustedMap.has(keyPort)) {
    return { matched: true, origin: keyPort, instanceKey: /** @type {string} */ (trustedMap.get(keyPort)) };
  }

  return { matched: false, reason: 'origin-not-trusted' };
}

/**
 * Validate a raw session id from the query string.
 * @param {string | null | undefined} raw
 * @returns {string | null}
 */
export function validateSessionId(raw) {
  if (raw == null) return null;
  if (typeof raw !== 'string') return null;

  // URLSearchParams already decodes once; reject empty after trim.
  const sessionId = raw.trim();
  if (sessionId.length < SESSION_ID_MIN_LENGTH || sessionId.length > SESSION_ID_MAX_LENGTH) {
    return null;
  }

  // Reject control characters and whitespace inside.
  for (let i = 0; i < sessionId.length; i++) {
    const code = sessionId.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) {
      return null;
    }
  }

  // Reject obvious injection / path traversal noise.
  if (sessionId.includes('\0') || sessionId.includes('://')) {
    return null;
  }

  return sessionId;
}

/**
 * Parse a page URL into trusted origin + session if eligible for owner registration.
 * @param {string} pageUrl
 * @param {Map<string, string>} trustedMap
 * @returns {SessionUrlParse}
 */
export function parseSessionUrl(pageUrl, trustedMap) {
  if (typeof pageUrl !== 'string' || pageUrl.trim() === '') {
    return { ok: false, reason: 'empty-url' };
  }

  let url;
  try {
    url = new URL(pageUrl);
  } catch {
    return { ok: false, reason: 'invalid-url' };
  }

  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return { ok: false, reason: 'scheme-rejected' };
  }

  if (url.username || url.password) {
    return { ok: false, reason: 'credentials-rejected' };
  }

  const originMatch = matchTrustedOrigin(pageUrl, trustedMap);
  if (!originMatch.matched) {
    return { ok: false, reason: originMatch.reason };
  }

  // Only the `session` query parameter establishes live owner registration.
  // Fragment is ignored. Missing/empty session => not an exact owner.
  const rawSession = url.searchParams.get('session');
  if (rawSession == null) {
    return { ok: false, reason: 'session-missing' };
  }

  const sessionId = validateSessionId(rawSession);
  if (!sessionId) {
    return { ok: false, reason: 'session-invalid' };
  }

  return {
    ok: true,
    origin: originMatch.origin,
    sessionId,
    pathname: url.pathname || '/',
  };
}

/**
 * Host permission pattern for a trusted origin (for manifest optional_host_permissions).
 * @param {string} origin
 * @returns {string | null}
 */
export function originToHostPermission(origin) {
  const norm = normalizeOrigin(origin);
  if (!norm) return null;
  // MV3 host permission: scheme://host[:port]/*
  return `${norm.origin}/*`;
}

/**
 * Safe origin fingerprint for logs (scheme+host hash-ish short token without full URL path).
 * Does not include path/query/session.
 * @param {string} origin
 * @returns {string}
 */
export function fingerprintOrigin(origin) {
  const norm = normalizeOrigin(origin);
  if (!norm) return '-';
  // Non-crypto short token: length + host slice — enough for diagnostics without leaking path.
  const s = norm.origin;
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  }
  return `o${(h >>> 0).toString(16).padStart(8, '0')}`;
}
