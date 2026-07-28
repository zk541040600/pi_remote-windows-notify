/**
 * Single-flight activation poller for Route Host.
 *
 * Extension periodically sends poll-activation with adapterKey through the
 * existing Native Messaging port. no-pending is a no-op; ready responses are
 * converted into the existing activate validation/focus flow; activate-result
 * must carry activationRequestId so daemon activation-status reaches a final result.
 *
 * Rules:
 * - single-flight (no overlapping poll/activate work)
 * - bounded interval
 * - pause while disconnected
 * - does not overlap heartbeat (separate timer; poll skips if busy)
 * - fail-closed on host/adapter errors
 * - no raw session / full URL logs
 */

import {
  DEFAULT_POLL_INTERVAL_MS,
  MIN_POLL_INTERVAL_MS,
  MAX_POLL_INTERVAL_MS,
  MessageTypes,
  RouteResults,
  RejectReasons,
} from './protocol.mjs';
import {
  handleActivateCommand,
  parsePollActivationResponse,
} from './activate.mjs';
import { fingerprintRoutingKey } from './routing-key.mjs';

/**
 * @typedef {import('./owner-registry.mjs').OwnerRegistry} OwnerRegistry
 * @typedef {import('./activate.mjs').BrowserFocusApi} BrowserFocusApi
 * @typedef {import('./activate.mjs').ActivateCommand} ActivateCommand
 *
 * @typedef {{
 *   send: (msg: Record<string, unknown>) => Promise<unknown>,
 *   post?: (msg: Record<string, unknown>) => void,
 *   isConnected: boolean,
 * }} PortLike
 */

/**
 * Clamp poll interval to protocol bounds.
 * @param {number | undefined} ms
 * @returns {number}
 */
export function clampPollIntervalMs(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms)) {
    return DEFAULT_POLL_INTERVAL_MS;
  }
  return Math.min(MAX_POLL_INTERVAL_MS, Math.max(MIN_POLL_INTERVAL_MS, Math.floor(ms)));
}

/**
 * Pure decision helper: should a poll tick run?
 * @param {{ connected: boolean, inFlight: boolean, stopped: boolean }} state
 * @returns {{ run: boolean, reason?: string }}
 */
export function shouldPollTick(state) {
  if (state.stopped) return { run: false, reason: 'stopped' };
  if (!state.connected) return { run: false, reason: 'disconnected' };
  if (state.inFlight) return { run: false, reason: 'in-flight' };
  return { run: true };
}

/**
 * Build poll-activation envelope (for unit tests without registry).
 * @param {{
 *   adapterKey: string,
 *   requestId: string,
 *   leaseTtlMs?: number,
 *   now?: number,
 *   protocolVersion?: number,
 *   nonce?: string,
 * }} args
 * @returns {Record<string, unknown>}
 */
export function buildPollActivationMessage(args) {
  const now = args.now ?? Date.now();
  return {
    protocolVersion: args.protocolVersion ?? 1,
    type: MessageTypes.PollActivation,
    requestId: args.requestId,
    nonce: args.nonce,
    issuedAtMs: now,
    expiresAtMs: now + 5_000,
    adapterKey: args.adapterKey,
    leaseTtlMs: args.leaseTtlMs,
  };
}

/**
 * Dedup key for a delivered activation command (prevents double-processing same delivery).
 * @param {ActivateCommand} command
 * @returns {string}
 */
export function activationDedupKey(command) {
  return (
    command.activationRequestId ||
    command.requestId ||
    `${command.snapshotId || ''}:${command.pageKey || ''}`
  );
}

export class ActivationPoller {
  /**
   * @param {{
   *   getRegistry: () => OwnerRegistry | null,
   *   getPort: () => PortLike | null,
   *   browserApi: BrowserFocusApi,
   *   log?: { info: Function, warn: Function, error: Function, debug?: Function },
   *   intervalMs?: number,
   *   now?: () => number,
   *   schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>,
   *   clearSchedule?: (id: ReturnType<typeof setTimeout>) => void,
   *   onActivateComplete?: (outcome: { result: string, reason?: string, activationRequestId?: string, elapsedMs: number }) => void,
   * }} opts
   */
  constructor(opts) {
    this.getRegistry = opts.getRegistry;
    this.getPort = opts.getPort;
    this.browserApi = opts.browserApi;
    this.log = opts.log ?? { info() {}, warn() {}, error() {}, debug() {} };
    this.intervalMs = clampPollIntervalMs(opts.intervalMs);
    this.now = opts.now ?? (() => Date.now());
    this.schedule = opts.schedule ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearSchedule = opts.clearSchedule ?? ((id) => clearTimeout(id));
    this.onActivateComplete = opts.onActivateComplete ?? (() => {});

    this.stopped = true;
    this.inFlight = false;
    /** @type {ReturnType<typeof setTimeout> | null} */
    this._timer = null;
    /** @type {Set<string>} recently handled activationRequestIds (bounded) */
    this._recentHandled = new Set();
    this._recentOrder = [];
    this._maxRecent = 64;
  }

  get isInFlight() {
    return this.inFlight;
  }

  get isRunning() {
    return !this.stopped;
  }

  start() {
    if (!this.stopped && this._timer != null) return;
    this.stopped = false;
    this.#armTimer();
    this.log.info('activation-poller-started', { intervalMs: this.intervalMs });
  }

  stop() {
    this.stopped = true;
    if (this._timer != null) {
      this.clearSchedule(this._timer);
      this._timer = null;
    }
    this.log.info('activation-poller-stopped', {});
  }

  /**
   * Pause polling without discarding recent-handled state (e.g. disconnect).
   * Timer keeps running but ticks no-op while disconnected (via shouldPollTick).
   */
  pause() {
    // Intentionally no-op beyond stop: disconnect is detected via getPort().isConnected.
    // Kept for API clarity / tests.
  }

  /**
   * Force one poll tick (used by tests and optional post-connect kick).
   * @returns {Promise<{ action: string, result?: string, reason?: string, activationRequestId?: string }>}
   */
  async tick() {
    return this.#runTick();
  }

  // --- private ---

  #armTimer() {
    if (this.stopped) return;
    if (this._timer != null) {
      this.clearSchedule(this._timer);
      this._timer = null;
    }
    this._timer = this.schedule(() => {
      this._timer = null;
      this.#runTick()
        .catch((err) => {
          this.log.warn('activation-poll-tick-error', { reason: err?.message || 'error' });
        })
        .finally(() => {
          if (!this.stopped) this.#armTimer();
        });
    }, this.intervalMs);
  }

  /**
   * @returns {Promise<{ action: string, result?: string, reason?: string, activationRequestId?: string }>}
   */
  async #runTick() {
    const port = this.getPort();
    const connected = Boolean(port?.isConnected);
    const gate = shouldPollTick({
      connected,
      inFlight: this.inFlight,
      stopped: this.stopped,
    });
    if (!gate.run) {
      return { action: 'skipped', reason: gate.reason };
    }

    const registry = this.getRegistry();
    if (!registry) {
      return { action: 'skipped', reason: 'no-registry' };
    }

    this.inFlight = true;
    try {
      const pollMsg = registry.buildPollActivation();
      let response;
      try {
        response = await port.send(pollMsg);
      } catch (err) {
        this.log.warn('poll-activation-send-failed', {
          reason: err?.message || 'error',
        });
        return { action: 'send-failed', reason: err?.message || 'send-failed' };
      }

      const parsed = parsePollActivationResponse(
        /** @type {Record<string, unknown>} */ (response || {}),
      );

      if (!parsed) {
        this.log.warn('poll-activation-unrecognized', {
          result:
            response && typeof response === 'object' && typeof response.result === 'string'
              ? response.result
              : 'unknown',
        });
        return { action: 'unrecognized' };
      }

      if (parsed.kind === 'no-pending') {
        return { action: 'no-pending' };
      }

      if (parsed.kind === 'error') {
        this.log.warn('poll-activation-error', {
          result: parsed.result,
          reason: parsed.reason || '',
        });
        return {
          action: 'host-error',
          result: parsed.result,
          reason: parsed.reason,
        };
      }

      // ready — run activate flow
      const command = parsed.command;
      const dedup = activationDedupKey(command);
      if (this._recentHandled.has(dedup)) {
        this.log.info('poll-activation-duplicate', {
          activationFp: dedup.slice(0, 12),
        });
        // Still report a result so daemon is not stuck if first attempt was lost?
        // Fail-closed: do not re-run focus; re-send last-known is unsafe without stored outcome.
        // Emit stale/replay-style activate-result so status can complete.
        await this.#sendActivateResult(registry, port, command, {
          result: RouteResults.Rejected,
          reason: RejectReasons.Replay,
          elapsedMs: 0,
        });
        return {
          action: 'duplicate',
          result: RouteResults.Rejected,
          reason: RejectReasons.Replay,
          activationRequestId: command.activationRequestId,
        };
      }

      this.log.info('poll-activation-ready', {
        activationFp: (command.activationRequestId || command.requestId).slice(0, 12),
        routingFp: fingerprintRoutingKey(command.routingKey),
        ownerFp: (command.ownerKey || '').slice(0, 12),
        pageFp: (command.pageKey || '').slice(0, 12),
      });

      const outcome = await handleActivateCommand({
        registry,
        browserApi: this.browserApi,
        command,
        now: this.now,
        log: this.log,
      });

      await this.#sendActivateResult(registry, port, command, outcome);
      this.#rememberHandled(dedup);

      this.onActivateComplete({
        result: outcome.result,
        reason: outcome.reason,
        activationRequestId: command.activationRequestId,
        elapsedMs: outcome.elapsedMs,
      });

      this.log.info('poll-activate-complete', {
        result: outcome.result,
        reason: outcome.reason || '',
        activationFp: (command.activationRequestId || command.requestId).slice(0, 12),
        elapsedMs: outcome.elapsedMs,
      });

      return {
        action: 'activated',
        result: outcome.result,
        reason: outcome.reason,
        activationRequestId: command.activationRequestId,
      };
    } finally {
      this.inFlight = false;
    }
  }

  /**
   * @param {OwnerRegistry} registry
   * @param {PortLike} port
   * @param {ActivateCommand} command
   * @param {{ result: string, reason?: string, elapsedMs: number }} outcome
   */
  async #sendActivateResult(registry, port, command, outcome) {
    const resultMsg = registry.buildActivateResult({
      requestId: command.requestId,
      activationRequestId: command.activationRequestId || command.requestId,
      notificationId: command.notificationId,
      snapshotId: command.snapshotId,
      result: outcome.result,
      reason: outcome.reason,
      elapsedMs: outcome.elapsedMs,
    });

    // Ensure activationRequestId is present for daemon correlation.
    if (!resultMsg.activationRequestId) {
      resultMsg.activationRequestId = command.activationRequestId || command.requestId;
    }

    try {
      if (typeof port.post === 'function') {
        // Fire-and-forget preferred; host may still reply but we don't block.
        port.post(resultMsg);
      } else {
        await port.send(resultMsg);
      }
    } catch (err) {
      this.log.error('activate-result-send-failed', {
        reason: err?.message || 'error',
        activationFp: (command.activationRequestId || command.requestId).slice(0, 12),
      });
    }
  }

  /**
   * @param {string} key
   */
  #rememberHandled(key) {
    if (this._recentHandled.has(key)) return;
    this._recentHandled.add(key);
    this._recentOrder.push(key);
    while (this._recentOrder.length > this._maxRecent) {
      const old = this._recentOrder.shift();
      if (old) this._recentHandled.delete(old);
    }
  }
}
