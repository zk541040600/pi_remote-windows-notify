/**
 * Runtime ID helpers: profileKey, pageKey, ownerKey, requestId, nonce.
 * tabId/windowId are never used as long-term business identity.
 */

import { MAX_OPAQUE_FIELD_LENGTH } from './protocol.mjs';

const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/**
 * @param {number} [bytes=16]
 * @returns {string}
 */
export function randomId(bytes = 16) {
  const arr = new Uint8Array(bytes);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(arr);
  } else {
    // Node fallback
    const nodeCrypto = globalThis.__piNotifyNodeCrypto;
    if (nodeCrypto?.randomFillSync) {
      nodeCrypto.randomFillSync(arr);
    } else {
      for (let i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256);
    }
  }
  let out = '';
  for (let i = 0; i < arr.length; i++) {
    out += ID_ALPHABET[arr[i] % ID_ALPHABET.length];
  }
  return out;
}

/**
 * UUID-like opaque id (hex, 32 chars) suitable for requestId / ownerKey.
 * @returns {string}
 */
export function randomHexId() {
  const arr = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(arr);
  } else {
    const nodeCrypto = globalThis.__piNotifyNodeCrypto;
    if (nodeCrypto?.randomFillSync) {
      nodeCrypto.randomFillSync(arr);
    } else {
      for (let i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256);
    }
  }
  return bufferToHex(arr);
}

/**
 * @param {Uint8Array} bytes
 * @returns {string}
 */
function bufferToHex(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

/**
 * Validate opaque id shape used by Route Host MessageValidator.IsOpaqueId.
 * @param {string} value
 * @returns {boolean}
 */
export function isOpaqueId(value) {
  if (typeof value !== 'string') return false;
  if (value.length < 8 || value.length > MAX_OPAQUE_FIELD_LENGTH) return false;
  for (let i = 0; i < value.length; i++) {
    const c = value[i];
    const ok =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c === '-' ||
      c === '_' ||
      c === '.';
    if (!ok) return false;
  }
  return true;
}

/**
 * pageKey identifies one document binding (ephemeral). Regenerated on navigation
 * that changes session or origin.
 * @returns {string}
 */
export function newPageKey() {
  return `pg_${randomHexId()}`;
}

/**
 * ownerKey identifies the adapter-local owner registration for a page.
 * @returns {string}
 */
export function newOwnerKey() {
  return `ow_${randomHexId()}`;
}

/**
 * @returns {string}
 */
export function newRequestId() {
  return randomHexId();
}

/**
 * @returns {string}
 */
export function newNonce() {
  return randomHexId();
}

/**
 * @returns {string}
 */
export function newAdapterKey(browserKind, profileKey) {
  const safeBrowser = String(browserKind || 'browser').replace(/[^a-z0-9-]/gi, '').slice(0, 16) || 'browser';
  const safeProfile = String(profileKey || 'profile').replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 24) || 'profile';
  return `ad_${safeBrowser}_${safeProfile}_${randomHexId().slice(0, 16)}`;
}

/**
 * Generate or accept a stable profileKey for this browser profile installation.
 * @param {string | null | undefined} existing
 * @returns {string}
 */
export function ensureProfileKey(existing) {
  if (typeof existing === 'string' && isOpaqueId(existing)) {
    return existing;
  }
  return `pf_${randomHexId()}`;
}

/**
 * Page fingerprint: short non-reversible token over routingKey + pageKey (not raw URL/session).
 * @param {string} routingKey
 * @param {string} pageKey
 * @returns {string}
 */
export function pageFingerprint(routingKey, pageKey) {
  const a = String(routingKey || '');
  const b = String(pageKey || '');
  // Prefer node crypto when present for tests; else simple mix (still not raw URL).
  const nodeCrypto = globalThis.__piNotifyNodeCrypto;
  const material = `pfp-v1\0${a}\0${b}`;
  if (nodeCrypto?.createHash) {
    return nodeCrypto.createHash('sha256').update(material, 'utf8').digest('hex').slice(0, 24);
  }
  let h1 = 0;
  let h2 = 0;
  for (let i = 0; i < material.length; i++) {
    h1 = (Math.imul(31, h1) + material.charCodeAt(i)) | 0;
    h2 = (Math.imul(17, h2) + material.charCodeAt(i) * (i + 3)) | 0;
  }
  return `${(h1 >>> 0).toString(16).padStart(8, '0')}${(h2 >>> 0).toString(16).padStart(8, '0')}`.slice(0, 24);
}
