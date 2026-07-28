/**
 * Live owner registry for browser tabs.
 * External-only: registration is driven solely by trusted URL + ?session=.
 * Atomic unregister/register on session/origin/tab changes.
 */

import {
  DEFAULT_LEASE_TTL_MS,
  MessageTypes,
  PROTOCOL_VERSION,
  RouteResults,
  RejectReasons,
} from './protocol.mjs';
import { computeRoutingKey, computeRoutingKeySync, fingerprintRoutingKey } from './routing-key.mjs';
import { parseSessionUrl, fingerprintOrigin } from './url-session.mjs';
import {
  newOwnerKey,
  newPageKey,
  newRequestId,
  newNonce,
  pageFingerprint,
  isOpaqueId,
} from './ids.mjs';

/**
 * @typedef {import('./url-session.mjs').SessionUrlParse} SessionUrlParse
 *
 * @typedef {{
 *   ownerKey: string,
 *   pageKey: string,
 *   tabId: number,
 *   windowId: number,
 *   instanceKey: string,
 *   routingKey: string,
 *   origin: string,
 *   pageFingerprint: string,
 *   registeredAtMs: number,
 *   lastSeenAtMs: number,
 * }} OwnerRecord
 *
 * @typedef {{
 *   type: string,
 *   protocolVersion: number,
 *   requestId: string,
 *   nonce?: string,
 *   issuedAtMs: number,
 *   expiresAtMs: number,
 *   adapterKey?: string,
 *   adapterKind?: string,
 *   browserKind?: string,
 *   profileKey?: string,
 *   ownerKey?: string,
 *   pageKey?: string,
 *   instanceKey?: string,
 *   routingKey?: string,
 *   leaseTtlMs?: number,
 *   pageFingerprint?: string,
 *   notificationId?: string,
 *   snapshotId?: string,
 *   activationRequestId?: string,
 *   result?: string,
 *   reason?: string,
 *   elapsedMs?: number,
 *   deadlineMs?: number,
 * }} RouteMessage
 */

/**
 * Pure owner registry + message builders. Transport is injected.
 */
export class OwnerRegistry {
  /**
   * @param {{
   *   browserKind: 'chrome' | 'edge',
   *   profileKey: string,
   *   adapterKey: string,
   *   trustedOrigins: Map<string, string>,
   *   leaseTtlMs?: number,
   *   now?: () => number,
   *   log?: { info: Function, warn: Function, error: Function, debug: Function },
   *   send?: (msg: RouteMessage) => Promise<unknown>,
   *   preferSyncRoutingKey?: boolean,
   * }} opts
   */
  constructor(opts) {
    this.browserKind = opts.browserKind;
    this.profileKey = opts.profileKey;
    this.adapterKey = opts.adapterKey;
    this.trustedOrigins = opts.trustedOrigins;
    this.leaseTtlMs = opts.leaseTtlMs ?? DEFAULT_LEASE_TTL_MS;
    this.now = opts.now ?? (() => Date.now());
    this.log = opts.log ?? { info() {}, warn() {}, error() {}, debug() {} };
    this.send = opts.send ?? (async () => ({ result: RouteResults.Ok }));
    this.preferSyncRoutingKey = opts.preferSyncRoutingKey === true;

    /** @type {Map<number, OwnerRecord>} tabId -> owner */
    this.byTabId = new Map();
    /** @type {Map<string, OwnerRecord>} ownerKey -> owner */
    this.byOwnerKey = new Map();
  }

  /**
   * Snapshot of live owners (for multi-owner metadata tests).
   * @returns {OwnerRecord[]}
   */
  listOwners() {
    return [...this.byOwnerKey.values()];
  }

  /**
   * Count owners sharing the same (instanceKey, routingKey).
   * @param {string} instanceKey
   * @param {string} routingKey
   * @returns {number}
   */
  countOwnersForRoute(instanceKey, routingKey) {
    let n = 0;
    for (const o of this.byOwnerKey.values()) {
      if (o.instanceKey === instanceKey && o.routingKey === routingKey) n += 1;
    }
    return n;
  }

  /**
   * @param {number} tabId
   * @returns {OwnerRecord | undefined}
   */
  getByTabId(tabId) {
    return this.byTabId.get(tabId);
  }

  /**
   * @param {string} ownerKey
   * @returns {OwnerRecord | undefined}
   */
  getByOwnerKey(ownerKey) {
    return this.byOwnerKey.get(ownerKey);
  }

  /**
   * Build envelope fields for outbound messages.
   * @param {string} type
   * @param {Partial<RouteMessage>} [extra]
   * @returns {RouteMessage}
   */
  buildMessage(type, extra = {}) {
    const issuedAtMs = this.now();
    return {
      protocolVersion: PROTOCOL_VERSION,
      type,
      requestId: newRequestId(),
      nonce: newNonce(),
      issuedAtMs,
      expiresAtMs: issuedAtMs + Math.min(this.leaseTtlMs, 30_000),
      ...extra,
    };
  }

  /**
   * Register adapter with Route Host.
   * @returns {Promise<unknown>}
   */
  async registerAdapter() {
    const msg = this.buildMessage(MessageTypes.RegisterAdapter, {
      adapterKey: this.adapterKey,
      adapterKind: this.browserKind,
      browserKind: this.browserKind,
      profileKey: this.profileKey,
      leaseTtlMs: this.leaseTtlMs,
    });
    this.log.info('register-adapter', {
      adapterKind: this.browserKind,
      profileFp: this.profileKey.slice(0, 12),
    });
    return this.send(msg);
  }

  /**
   * Heartbeat for adapter + all live owners (lease refresh).
   * @returns {Promise<unknown>}
   */
  async heartbeat() {
    const msg = this.buildMessage(MessageTypes.Heartbeat, {
      adapterKey: this.adapterKey,
      leaseTtlMs: this.leaseTtlMs,
    });
    return this.send(msg);
  }

  /**
   * Process a tab URL observation. Atomic unregister/register when session/origin changes.
   * @param {{ tabId: number, windowId: number, url: string | undefined | null }} tab
   * @returns {Promise<{ action: string, owner?: OwnerRecord, reason?: string }>}
   */
  async observeTab(tab) {
    const { tabId, windowId } = tab;
    const url = tab.url ?? '';
    const existing = this.byTabId.get(tabId);

    if (!url || url.startsWith('chrome://') || url.startsWith('edge://') || url.startsWith('about:')) {
      if (existing) {
        await this.#unregisterLocal(existing, 'tab-url-unavailable');
        return { action: 'unregistered', reason: 'tab-url-unavailable' };
      }
      return { action: 'noop', reason: 'tab-url-unavailable' };
    }

    const parsed = parseSessionUrl(url, this.trustedOrigins);
    if (!parsed.ok) {
      if (existing) {
        await this.#unregisterLocal(existing, parsed.reason);
        return { action: 'unregistered', reason: parsed.reason };
      }
      return { action: 'noop', reason: parsed.reason };
    }

    const resolvedInstance = this.#instanceKeyForOrigin(parsed.origin);
    if (!resolvedInstance) {
      if (existing) {
        await this.#unregisterLocal(existing, 'instance-unresolved');
        return { action: 'unregistered', reason: 'instance-unresolved' };
      }
      return { action: 'noop', reason: 'instance-unresolved' };
    }

    const rk = await this.#computeRk(resolvedInstance, parsed.sessionId);

    if (existing) {
      const same =
        existing.instanceKey === resolvedInstance &&
        existing.routingKey === rk &&
        existing.windowId === windowId;

      if (same) {
        existing.lastSeenAtMs = this.now();
        // Re-register / heartbeat lease (idempotent register-owner)
        await this.#sendRegisterOwner(existing);
        return { action: 'refreshed', owner: existing };
      }

      // Session/origin/window changed: atomic unregister then register new pageKey.
      await this.#unregisterLocal(existing, 'session-or-origin-changed');
    }

    const pageKey = newPageKey();
    const ownerKey = newOwnerKey();
    const fp = pageFingerprint(rk, pageKey);
    /** @type {OwnerRecord} */
    const owner = {
      ownerKey,
      pageKey,
      tabId,
      windowId,
      instanceKey: resolvedInstance,
      routingKey: rk,
      origin: parsed.origin,
      pageFingerprint: fp,
      registeredAtMs: this.now(),
      lastSeenAtMs: this.now(),
    };

    this.byTabId.set(tabId, owner);
    this.byOwnerKey.set(ownerKey, owner);

    await this.#sendRegisterOwner(owner);
    this.log.info('owner-registered', {
      ownerFp: owner.ownerKey.slice(0, 12),
      pageFp: owner.pageKey.slice(0, 12),
      routingFp: fingerprintRoutingKey(owner.routingKey),
      originFp: fingerprintOrigin(owner.origin),
      tabId: owner.tabId,
      windowId: owner.windowId,
      browserKind: this.browserKind,
    });

    return { action: 'registered', owner };
  }

  /**
   * Tab closed.
   * @param {number} tabId
   */
  async removeTab(tabId) {
    const existing = this.byTabId.get(tabId);
    if (!existing) return { action: 'noop' };
    await this.#unregisterLocal(existing, 'tab-closed');
    return { action: 'unregistered', reason: 'tab-closed' };
  }

  /**
   * Clear all owners (extension suspend / disconnect).
   */
  async clearAll(reason = 'clear-all') {
    const owners = [...this.byOwnerKey.values()];
    for (const o of owners) {
      await this.#unregisterLocal(o, reason);
    }
  }

  /**
   * Validate an activate command against current local owner state (before focusing).
   * @param {{
   *   ownerKey?: string,
   *   pageKey: string,
   *   routingKey: string,
   *   instanceKey: string,
   *   pageFingerprint?: string,
   * }} cmd
   * @returns {{ ok: true, owner: OwnerRecord } | { ok: false, result: string, reason: string }}
   */
  validateActivateTarget(cmd) {
    if (!cmd?.pageKey || !cmd?.routingKey || !cmd?.instanceKey) {
      return { ok: false, result: RouteResults.Rejected, reason: RejectReasons.MissingField };
    }

    /** @type {OwnerRecord | undefined} */
    let owner;
    if (cmd.ownerKey && this.byOwnerKey.has(cmd.ownerKey)) {
      owner = this.byOwnerKey.get(cmd.ownerKey);
    } else {
      // Fall back to pageKey scan (ownerKey optional for resilience).
      for (const o of this.byOwnerKey.values()) {
        if (o.pageKey === cmd.pageKey) {
          owner = o;
          break;
        }
      }
    }

    if (!owner) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.TabMissing };
    }

    if (owner.pageKey !== cmd.pageKey) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.PageKeyMismatch };
    }

    if (owner.routingKey !== cmd.routingKey || owner.instanceKey !== cmd.instanceKey) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.RoutingKeyMismatch };
    }

    if (
      cmd.pageFingerprint &&
      owner.pageFingerprint &&
      cmd.pageFingerprint !== owner.pageFingerprint
    ) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.OwnerChanged };
    }

    return { ok: true, owner };
  }

  /**
   * After browser focus, re-check live URL still maps to the frozen routingKey.
   * @param {OwnerRecord} owner
   * @param {string | undefined | null} liveUrl
   * @returns {Promise<{ ok: true } | { ok: false, result: string, reason: string }>}
   */
  async confirmLiveUrl(owner, liveUrl) {
    if (!liveUrl) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.SessionUnresolved };
    }

    const parsed = parseSessionUrl(liveUrl, this.trustedOrigins);
    if (!parsed.ok) {
      return { ok: false, result: RouteResults.Stale, reason: parsed.reason };
    }

    const instanceKey = this.#instanceKeyForOrigin(parsed.origin);
    if (!instanceKey || instanceKey !== owner.instanceKey) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.OriginRejected };
    }

    const rk = await this.#computeRk(instanceKey, parsed.sessionId);
    if (rk !== owner.routingKey) {
      return { ok: false, result: RouteResults.Stale, reason: RejectReasons.RoutingKeyMismatch };
    }

    return { ok: true };
  }

  /**
   * Build activate-result message.
   * Prefer activationRequestId so daemon activation-status can reach a final result.
   * @param {{
   *   requestId?: string,
   *   activationRequestId?: string,
   *   notificationId?: string,
   *   snapshotId?: string,
   *   result: string,
   *   reason?: string,
   *   elapsedMs?: number,
   * }} args
   * @returns {RouteMessage}
   */
  buildActivateResult(args) {
    const activationRequestId =
      (typeof args.activationRequestId === 'string' && args.activationRequestId) ||
      (typeof args.requestId === 'string' && args.requestId) ||
      '';
    const msg = this.buildMessage(MessageTypes.ActivateResult, {
      // Envelope requestId is unique per message; activationRequestId correlates the pending activation.
      activationRequestId,
      notificationId: args.notificationId,
      snapshotId: args.snapshotId,
      result: args.result,
      reason: args.reason,
      elapsedMs: args.elapsedMs,
      adapterKey: this.adapterKey,
    });
    // Keep requestId as a distinct envelope id (already set by buildMessage),
    // but if caller only supplied one id, also put it on requestId for legacy hosts.
    if (activationRequestId && !args.requestId) {
      // leave generated requestId; activationRequestId carries correlation
    } else if (typeof args.requestId === 'string' && args.requestId) {
      // Preserve explicit requestId when provided (push-activate path).
      msg.requestId = args.requestId;
      if (!msg.activationRequestId) {
        msg.activationRequestId = args.requestId;
      }
    }
    return msg;
  }

  /**
   * Build a poll-activation request for this adapter.
   * @returns {RouteMessage}
   */
  buildPollActivation() {
    return this.buildMessage(MessageTypes.PollActivation, {
      adapterKey: this.adapterKey,
      leaseTtlMs: this.leaseTtlMs,
    });
  }

  // --- private ---

  /**
   * @param {string} origin
   * @returns {string | null}
   */
  #instanceKeyForOrigin(origin) {
    if (this.trustedOrigins.has(origin)) {
      return /** @type {string} */ (this.trustedOrigins.get(origin));
    }
    // try with/without default port variants already stored in map by buildTrustedOriginMap
    return null;
  }

  /**
   * @param {string} instanceKey
   * @param {string} sessionId
   * @returns {Promise<string>}
   */
  async #computeRk(instanceKey, sessionId) {
    if (this.preferSyncRoutingKey) {
      try {
        return computeRoutingKeySync(instanceKey, sessionId);
      } catch {
        // fall through
      }
    }
    return computeRoutingKey(instanceKey, sessionId);
  }

  /**
   * @param {OwnerRecord} owner
   */
  async #sendRegisterOwner(owner) {
    const msg = this.buildMessage(MessageTypes.RegisterOwner, {
      adapterKey: this.adapterKey,
      adapterKind: this.browserKind,
      browserKind: this.browserKind,
      profileKey: this.profileKey,
      ownerKey: owner.ownerKey,
      pageKey: owner.pageKey,
      instanceKey: owner.instanceKey,
      routingKey: owner.routingKey,
      pageFingerprint: owner.pageFingerprint,
      leaseTtlMs: this.leaseTtlMs,
    });
    return this.send(msg);
  }

  /**
   * @param {OwnerRecord} owner
   * @param {string} reason
   */
  async #unregisterLocal(owner, reason) {
    this.byTabId.delete(owner.tabId);
    this.byOwnerKey.delete(owner.ownerKey);

    const msg = this.buildMessage(MessageTypes.UnregisterOwner, {
      adapterKey: this.adapterKey,
      ownerKey: owner.ownerKey,
      pageKey: owner.pageKey,
    });

    this.log.info('owner-unregistered', {
      ownerFp: owner.ownerKey.slice(0, 12),
      pageFp: owner.pageKey.slice(0, 12),
      routingFp: fingerprintRoutingKey(owner.routingKey),
      reason,
      tabId: owner.tabId,
    });

    try {
      await this.send(msg);
    } catch {
      // fail-closed locally even if host unreachable
    }
  }
}

/**
 * Multi-owner metadata for a route: used by tests and diagnostics (never to pick a winner).
 * @param {OwnerRegistry} registry
 * @param {string} instanceKey
 * @param {string} routingKey
 * @returns {{ count: number, ownerKeys: string[], pageKeys: string[], tabIds: number[] }}
 */
export function multiOwnerMetadata(registry, instanceKey, routingKey) {
  const owners = registry.listOwners().filter(
    (o) => o.instanceKey === instanceKey && o.routingKey === routingKey,
  );
  return {
    count: owners.length,
    ownerKeys: owners.map((o) => o.ownerKey),
    pageKeys: owners.map((o) => o.pageKey),
    tabIds: owners.map((o) => o.tabId),
  };
}

/**
 * @param {unknown} value
 * @returns {value is RouteMessage}
 */
export function isActivateCommand(value) {
  if (!value || typeof value !== 'object') return false;
  const v = /** @type {Record<string, unknown>} */ (value);
  return v.type === MessageTypes.Activate && typeof v.requestId === 'string';
}

export { isOpaqueId };
