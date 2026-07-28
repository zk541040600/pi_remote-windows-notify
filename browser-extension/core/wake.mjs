/**
 * Host→extension unsolicited wake handling.
 *
 * Native Messaging inbound traffic wakes the MV3 service worker. The Route Host
 * relay emits bounded `type=wake` frames so poll-activation can run while idle.
 *
 * Rules:
 * - wake frames carry only protocolVersion / type / seq
 * - never contain raw session, URL, routing key, instance key, token, or user content
 * - dispatch forces one existing ActivationPoller.tick() through single-flight
 * - does not create a second activation path or bypass tab/window/URL validation
 */

import {
  MessageTypes,
  PROTOCOL_VERSION,
  WAKE_MAINTENANCE_INTERVAL_MS,
} from './protocol.mjs';

/** Canonical wake fields; any extra field makes the frame non-actionable. */
export const WAKE_FIELDS = Object.freeze(['protocolVersion', 'type', 'seq']);

/** Fields called out explicitly in validation diagnostics and privacy tests. */
export const WAKE_FORBIDDEN_FIELDS = Object.freeze([
  'sessionId',
  'session',
  'rawSessionId',
  'routingKey',
  'instanceKey',
  'token',
  'notifyToken',
  'url',
  'pageUrl',
  'href',
  'body',
  'title',
  'cwd',
  'cwdBase',
  'tabTitle',
  'ownerKey',
  'pageKey',
  'adapterKey',
  'notificationId',
  'snapshotId',
  'activationRequestId',
]);

/**
 * @param {unknown} raw
 * @returns {raw is { type: string, protocolVersion?: number, seq?: number }}
 */
export function isWakeMessage(raw) {
  if (!raw || typeof raw !== 'object') return false;
  const msg = /** @type {Record<string, unknown>} */ (raw);
  return msg.type === MessageTypes.Wake;
}

/**
 * Validate that a wake frame is minimal and free of sensitive material.
 * @param {unknown} raw
 * @returns {{ ok: true } | { ok: false, reason: string }}
 */
export function validateWakeMessage(raw) {
  if (!isWakeMessage(raw)) {
    return { ok: false, reason: 'not-wake' };
  }
  const msg = /** @type {Record<string, unknown>} */ (raw);

  if (msg.protocolVersion !== PROTOCOL_VERSION) {
    return { ok: false, reason: 'protocol-mismatch' };
  }

  if (!Number.isSafeInteger(msg.seq) || /** @type {number} */ (msg.seq) < 1) {
    return { ok: false, reason: 'invalid-seq' };
  }

  for (const key of WAKE_FORBIDDEN_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(msg, key)) {
      return { ok: false, reason: `forbidden-field:${key}` };
    }
  }

  for (const key of Object.keys(msg)) {
    if (!WAKE_FIELDS.includes(key)) {
      return { ok: false, reason: `unknown-field:${key}` };
    }
  }

  return { ok: true };
}

/**
 * Build a canonical wake frame (for tests / host parity).
 * @param {number | bigint} seq
 * @returns {{ protocolVersion: number, type: string, seq: number }}
 */
export function buildWakeMessage(seq) {
  return {
    protocolVersion: PROTOCOL_VERSION,
    type: MessageTypes.Wake,
    seq: Number(seq),
  };
}

/**
 * Decide whether wake-driven lease maintenance should run.
 * @param {{ lastMaintenanceMs: number, nowMs: number, intervalMs?: number }} args
 * @returns {boolean}
 */
export function shouldRunWakeMaintenance(args) {
  const interval = args.intervalMs ?? WAKE_MAINTENANCE_INTERVAL_MS;
  if (!Number.isFinite(args.lastMaintenanceMs) || !Number.isFinite(args.nowMs)) {
    return false;
  }
  return args.nowMs - args.lastMaintenanceMs >= interval;
}

/**
 * Refresh only owners whose current live tab still proves the same page/session route.
 * Uses owner heartbeat rather than register-owner, so a close/navigation race cannot
 * recreate an owner that an event handler already removed.
 *
 * @param {{
 *   registry: import('./owner-registry.mjs').OwnerRegistry,
 *   tabsGet: (tabId: number) => Promise<{ windowId?: number, url?: string } | undefined>,
 *   shouldContinue?: () => boolean,
 *   now?: () => number,
 * }} args
 * @returns {Promise<{ refreshed: number, removed: number, skipped: number }>}
 */
export async function refreshLiveOwnerLeases(args) {
  const { registry } = args;
  const shouldContinue = args.shouldContinue ?? (() => true);
  const now = args.now ?? Date.now;
  const counts = { refreshed: 0, removed: 0, skipped: 0 };

  for (const owner of registry.listOwners()) {
    if (!shouldContinue()) break;

    let tab;
    try {
      tab = await args.tabsGet(owner.tabId);
    } catch {
      const current = registry.getByTabId(owner.tabId);
      if (current?.ownerKey === owner.ownerKey && current.pageKey === owner.pageKey) {
        await registry.removeTab(owner.tabId);
        counts.removed += 1;
      } else {
        counts.skipped += 1;
      }
      continue;
    }

    let current = registry.getByTabId(owner.tabId);
    if (current?.ownerKey !== owner.ownerKey || current.pageKey !== owner.pageKey) {
      counts.skipped += 1;
      continue;
    }

    const live = await registry.confirmLiveUrl(owner, tab?.url);
    current = registry.getByTabId(owner.tabId);
    if (current?.ownerKey !== owner.ownerKey || current.pageKey !== owner.pageKey) {
      counts.skipped += 1;
      continue;
    }

    if (!live.ok) {
      await registry.removeTab(owner.tabId);
      counts.removed += 1;
      continue;
    }

    if (typeof tab?.windowId === 'number') {
      owner.windowId = tab.windowId;
    }
    owner.lastSeenAtMs = now();

    await registry.send(
      registry.buildMessage(MessageTypes.Heartbeat, {
        adapterKey: registry.adapterKey,
        ownerKey: owner.ownerKey,
        leaseTtlMs: registry.leaseTtlMs,
      }),
    );
    counts.refreshed += 1;
  }

  return counts;
}

/**
 * Dispatch a wake frame to an existing ActivationPoller.
 * Forces one tick through the single-flight gate; does not bypass validation.
 *
 * @param {unknown} raw
 * @param {{
 *   tick: () => Promise<{ action: string, result?: string, reason?: string, activationRequestId?: string }>,
 *   isRunning?: boolean,
 * }} poller
 * @param {{
 *   validate?: boolean,
 *   onInvalid?: (reason: string) => void,
 * }} [opts]
 * @returns {Promise<{ action: string, result?: string, reason?: string, activationRequestId?: string } | null>}
 */
export async function dispatchWakeToPoller(raw, poller, opts = {}) {
  if (!isWakeMessage(raw)) {
    return null;
  }

  if (opts.validate !== false) {
    const check = validateWakeMessage(raw);
    if (!check.ok) {
      opts.onInvalid?.(check.reason);
      return { action: 'skipped', reason: 'invalid-wake' };
    }
  }

  if (!poller || typeof poller.tick !== 'function') {
    return { action: 'skipped', reason: 'no-poller' };
  }

  return poller.tick();
}
