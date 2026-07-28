/**
 * Extension config: trusted Pi Web origins -> instanceKey, browserKind, lease TTL.
 * Persisted in chrome.storage.local (profile-scoped). No secrets / raw session IDs.
 */

import { DEFAULT_LEASE_TTL_MS, MAX_LEASE_TTL_MS, MIN_LEASE_TTL_MS } from './protocol.mjs';
import { buildTrustedOriginMap, normalizeOrigin, originToHostPermission } from './url-session.mjs';
import { ensureProfileKey, isOpaqueId } from './ids.mjs';

export const STORAGE_KEYS = Object.freeze({
  profileKey: 'profileKey',
  trustedOrigins: 'trustedOrigins',
  leaseTtlMs: 'leaseTtlMs',
  browserKind: 'browserKind',
  adapterKey: 'adapterKey',
});

/**
 * @typedef {{ origin: string, instanceKey: string }} TrustedOriginEntry
 * @typedef {{
 *   profileKey: string,
 *   trustedOrigins: TrustedOriginEntry[],
 *   leaseTtlMs: number,
 *   browserKind: 'chrome' | 'edge',
 *   adapterKey?: string,
 * }} ExtensionConfig
 */

/**
 * @param {unknown} raw
 * @param {{ browserKind?: 'chrome' | 'edge' }} [defaults]
 * @returns {ExtensionConfig}
 */
export function normalizeConfig(raw, defaults = {}) {
  const obj = raw && typeof raw === 'object' ? /** @type {Record<string, unknown>} */ (raw) : {};

  const browserKind =
    obj.browserKind === 'edge' || defaults.browserKind === 'edge' ? 'edge' : 'chrome';

  const profileKey = ensureProfileKey(
    typeof obj.profileKey === 'string' ? obj.profileKey : undefined,
  );

  /** @type {TrustedOriginEntry[]} */
  let trustedOrigins = [];
  if (Array.isArray(obj.trustedOrigins)) {
    for (const entry of obj.trustedOrigins) {
      if (!entry || typeof entry !== 'object') continue;
      const e = /** @type {Record<string, unknown>} */ (entry);
      const originRaw = typeof e.origin === 'string' ? e.origin : '';
      const instanceKey = typeof e.instanceKey === 'string' ? e.instanceKey.trim() : '';
      const norm = normalizeOrigin(originRaw);
      // instanceKey is UUID-like opaque (dashes allowed via charset check).
      if (!norm || instanceKey.length < 8 || instanceKey.length > 128) continue;
      if (!/^[A-Za-z0-9._+-]+$/.test(instanceKey)) continue;
      trustedOrigins.push({ origin: norm.origin, instanceKey });
    }
  } else if (obj.trustedOrigins && typeof obj.trustedOrigins === 'object') {
    for (const [originRaw, instanceKeyRaw] of Object.entries(
      /** @type {Record<string, unknown>} */ (obj.trustedOrigins),
    )) {
      const instanceKey = typeof instanceKeyRaw === 'string' ? instanceKeyRaw.trim() : '';
      const norm = normalizeOrigin(originRaw);
      if (!norm || instanceKey.length < 8 || instanceKey.length > 128) continue;
      if (!/^[A-Za-z0-9._+-]+$/.test(instanceKey)) continue;
      trustedOrigins.push({ origin: norm.origin, instanceKey });
    }
  }

  // Dedupe by origin (last wins).
  const byOrigin = new Map();
  for (const e of trustedOrigins) byOrigin.set(e.origin, e.instanceKey);
  trustedOrigins = [...byOrigin.entries()].map(([origin, instanceKey]) => ({ origin, instanceKey }));

  let leaseTtlMs =
    typeof obj.leaseTtlMs === 'number' && Number.isFinite(obj.leaseTtlMs)
      ? Math.trunc(obj.leaseTtlMs)
      : DEFAULT_LEASE_TTL_MS;
  if (leaseTtlMs < MIN_LEASE_TTL_MS) leaseTtlMs = MIN_LEASE_TTL_MS;
  if (leaseTtlMs > MAX_LEASE_TTL_MS) leaseTtlMs = MAX_LEASE_TTL_MS;

  const adapterKey =
    typeof obj.adapterKey === 'string' && isOpaqueId(obj.adapterKey) ? obj.adapterKey : undefined;

  return {
    profileKey,
    trustedOrigins,
    leaseTtlMs,
    browserKind,
    adapterKey,
  };
}

/**
 * @param {ExtensionConfig} config
 * @returns {Map<string, string>}
 */
export function configToTrustedMap(config) {
  return buildTrustedOriginMap(config.trustedOrigins);
}

/**
 * Host permissions implied by config (for optional_permissions / documentation).
 * @param {ExtensionConfig} config
 * @returns {string[]}
 */
export function configHostPermissions(config) {
  const perms = new Set();
  for (const e of config.trustedOrigins) {
    const p = originToHostPermission(e.origin);
    if (p) perms.add(p);
  }
  return [...perms];
}

/**
 * Storage load helper (inject chrome.storage.local-like API).
 * @param {{ get: (keys: string[]) => Promise<Record<string, unknown>> | void }} storage
 * @param {{ browserKind?: 'chrome' | 'edge' }} [defaults]
 * @returns {Promise<ExtensionConfig>}
 */
export async function loadConfig(storage, defaults = {}) {
  const keys = Object.values(STORAGE_KEYS);
  const got = await Promise.resolve(storage.get(keys));
  return normalizeConfig(got ?? {}, defaults);
}

/**
 * @param {{ set: (items: Record<string, unknown>) => Promise<void> | void }} storage
 * @param {ExtensionConfig} config
 */
export async function saveConfig(storage, config) {
  const normalized = normalizeConfig(config, { browserKind: config.browserKind });
  await Promise.resolve(
    storage.set({
      [STORAGE_KEYS.profileKey]: normalized.profileKey,
      [STORAGE_KEYS.trustedOrigins]: normalized.trustedOrigins,
      [STORAGE_KEYS.leaseTtlMs]: normalized.leaseTtlMs,
      [STORAGE_KEYS.browserKind]: normalized.browserKind,
      ...(normalized.adapterKey
        ? { [STORAGE_KEYS.adapterKey]: normalized.adapterKey }
        : {}),
    }),
  );
  return normalized;
}

/**
 * Default empty config for first run (options page must set origins).
 * @param {'chrome' | 'edge'} browserKind
 * @returns {ExtensionConfig}
 */
export function emptyConfig(browserKind) {
  return normalizeConfig({ browserKind, trustedOrigins: [] }, { browserKind });
}
