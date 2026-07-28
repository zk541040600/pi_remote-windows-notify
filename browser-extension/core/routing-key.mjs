/**
 * routingKey = SHA-256("pi-web-route-v1\0" + instanceKey + "\0" + rawSessionId) as lowercase hex.
 * Full 256-bit; never truncated. Raw session IDs must not be logged.
 *
 * Works in Node (node:crypto) and browsers (Web Crypto subtle).
 */

import { ROUTING_KEY_DOMAIN } from './protocol.mjs';

/**
 * @param {string} instanceKey
 * @param {string} rawSessionId
 * @returns {Promise<string>} lowercase hex SHA-256
 */
export async function computeRoutingKey(instanceKey, rawSessionId) {
  if (typeof instanceKey !== 'string' || instanceKey.trim() === '') {
    throw new Error('instanceKey is required');
  }
  if (typeof rawSessionId !== 'string' || rawSessionId.trim() === '') {
    throw new Error('rawSessionId is required');
  }

  const payload = buildPayload(instanceKey, rawSessionId);
  return sha256Hex(payload);
}

/**
 * Synchronous compute for Node tests (uses node:crypto when available).
 * @param {string} instanceKey
 * @param {string} rawSessionId
 * @returns {string}
 */
export function computeRoutingKeySync(instanceKey, rawSessionId) {
  if (typeof instanceKey !== 'string' || instanceKey.trim() === '') {
    throw new Error('instanceKey is required');
  }
  if (typeof rawSessionId !== 'string' || rawSessionId.trim() === '') {
    throw new Error('rawSessionId is required');
  }

  const payload = buildPayload(instanceKey, rawSessionId);

  // Prefer node:crypto for deterministic tests / service-worker polyfill path.
  try {
    // Dynamic import not available sync; use createRequire pattern via globalThis hook or crypto.
    const nodeCrypto = globalThis.__piNotifyNodeCrypto;
    if (nodeCrypto?.createHash) {
      return nodeCrypto.createHash('sha256').update(payload).digest('hex');
    }
  } catch {
    // fall through
  }

  // Browser path must use async; sync throws so callers use computeRoutingKey.
  throw new Error('computeRoutingKeySync requires Node crypto (set globalThis.__piNotifyNodeCrypto)');
}

/**
 * Short fingerprint for logs (first 12 hex chars).
 * @param {string} routingKey
 * @returns {string}
 */
export function fingerprintRoutingKey(routingKey) {
  if (!routingKey) return '';
  const lower = String(routingKey).toLowerCase();
  return lower.length <= 12 ? lower : lower.slice(0, 12);
}

/**
 * Fingerprint an instanceKey without logging the raw UUID.
 * @param {string} instanceKey
 * @returns {Promise<string>}
 */
export async function fingerprintInstance(instanceKey) {
  if (!instanceKey) return '';
  const bytes = new TextEncoder().encode(instanceKey);
  const hex = await sha256Hex(bytes);
  return hex.slice(0, 12);
}

/**
 * @param {string} instanceKey
 * @returns {string}
 */
export function fingerprintInstanceSync(instanceKey) {
  if (!instanceKey) return '';
  const bytes = new TextEncoder().encode(instanceKey);
  const nodeCrypto = globalThis.__piNotifyNodeCrypto;
  if (!nodeCrypto?.createHash) {
    throw new Error('fingerprintInstanceSync requires Node crypto');
  }
  return nodeCrypto.createHash('sha256').update(bytes).digest('hex').slice(0, 12);
}

/**
 * @param {string} ownerKey
 * @returns {string}
 */
export function fingerprintOwner(ownerKey) {
  return fingerprintRoutingKey(ownerKey);
}

/**
 * @param {string} instanceKey
 * @param {string} rawSessionId
 * @returns {Uint8Array}
 */
function buildPayload(instanceKey, rawSessionId) {
  const enc = new TextEncoder();
  const domain = enc.encode(ROUTING_KEY_DOMAIN + '\0');
  const inst = enc.encode(instanceKey);
  const sess = enc.encode(rawSessionId);
  const payload = new Uint8Array(domain.length + inst.length + 1 + sess.length);
  payload.set(domain, 0);
  payload.set(inst, domain.length);
  payload[domain.length + inst.length] = 0;
  payload.set(sess, domain.length + inst.length + 1);
  return payload;
}

/**
 * @param {Uint8Array|Buffer} data
 * @returns {Promise<string>}
 */
async function sha256Hex(data) {
  const nodeCrypto = globalThis.__piNotifyNodeCrypto;
  if (nodeCrypto?.createHash) {
    return nodeCrypto.createHash('sha256').update(data).digest('hex');
  }

  if (globalThis.crypto?.subtle) {
    const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    const digest = await globalThis.crypto.subtle.digest('SHA-256', buf);
    return bufferToHex(new Uint8Array(digest));
  }

  throw new Error('No SHA-256 implementation available');
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
