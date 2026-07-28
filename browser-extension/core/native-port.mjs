/**
 * Native Messaging port with reconnect.
 * Host name: io.pi.notify.route (primary).
 * Service worker uses chrome.runtime.connectNative; tests inject a fake port factory.
 */

import { NATIVE_HOST_NAME, MessageTypes, RouteResults } from './protocol.mjs';

/**
 * @typedef {{
 *   postMessage: (msg: unknown) => void,
 *   disconnect: () => void,
 *   onMessage: { addListener: (fn: (msg: unknown) => void) => void, removeListener?: (fn: Function) => void },
 *   onDisconnect: { addListener: (fn: () => void) => void, removeListener?: (fn: Function) => void },
 *   name?: string,
 * }} NativePort
 */

/**
 * @typedef {{
 *   connectNative: (name: string) => NativePort,
 *   lastError?: { message?: string } | null,
 * }} RuntimeApi
 */

export class NativePortClient {
  /**
   * @param {{
   *   runtime: RuntimeApi,
   *   hostName?: string,
   *   log?: { info: Function, warn: Function, error: Function, debug: Function },
   *   onMessage?: (msg: unknown) => void | Promise<void>,
   *   onConnectionChange?: (connected: boolean, meta?: Record<string, unknown>) => void,
   *   reconnectBaseMs?: number,
   *   reconnectMaxMs?: number,
   *   now?: () => number,
   *   schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>,
   *   clearSchedule?: (id: ReturnType<typeof setTimeout>) => void,
   * }} opts
   */
  constructor(opts) {
    this.runtime = opts.runtime;
    this.hostName = opts.hostName ?? NATIVE_HOST_NAME;
    this.log = opts.log ?? { info() {}, warn() {}, error() {}, debug() {} };
    this.onMessage = opts.onMessage ?? (() => {});
    this.onConnectionChange = opts.onConnectionChange ?? (() => {});
    this.reconnectBaseMs = opts.reconnectBaseMs ?? 500;
    this.reconnectMaxMs = opts.reconnectMaxMs ?? 15_000;
    this.now = opts.now ?? (() => Date.now());
    this.schedule = opts.schedule ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearSchedule = opts.clearSchedule ?? ((id) => clearTimeout(id));

    /** @type {NativePort | null} */
    this.port = null;
    this.connected = false;
    this.stopped = false;
    this.attempt = 0;
    /** @type {ReturnType<typeof setTimeout> | null} */
    this._reconnectTimer = null;
    /** @type {Map<string, { resolve: Function, reject: Function, timer: ReturnType<typeof setTimeout> }>} */
    this._pending = new Map();
    this._responseTimeoutMs = 8_000;
  }

  start() {
    this.stopped = false;
    this.#connect();
  }

  stop() {
    this.stopped = true;
    if (this._reconnectTimer != null) {
      this.clearSchedule(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    this.#rejectAllPending('stopped');
    if (this.port) {
      try {
        this.port.disconnect();
      } catch {
        // ignore
      }
      this.port = null;
    }
    if (this.connected) {
      this.connected = false;
      this.onConnectionChange(false, { reason: 'stopped' });
    }
  }

  /**
   * @param {Record<string, unknown>} msg
   * @returns {Promise<unknown>}
   */
  send(msg) {
    if (!this.connected || !this.port) {
      return Promise.reject(new Error('native-port-disconnected'));
    }

    const requestId = typeof msg.requestId === 'string' ? msg.requestId : '';
    const expectsResponse = Boolean(requestId) && msg.type !== MessageTypes.ActivateResult;

    if (!expectsResponse) {
      try {
        this.port.postMessage(msg);
        return Promise.resolve({ result: RouteResults.Ok });
      } catch (err) {
        this.#handleDisconnect('post-failed');
        return Promise.reject(err);
      }
    }

    return new Promise((resolve, reject) => {
      const timer = this.schedule(() => {
        this._pending.delete(requestId);
        reject(new Error('native-response-timeout'));
      }, this._responseTimeoutMs);

      this._pending.set(requestId, { resolve, reject, timer });

      try {
        this.port.postMessage(msg);
      } catch (err) {
        this.clearSchedule(timer);
        this._pending.delete(requestId);
        this.#handleDisconnect('post-failed');
        reject(err);
      }
    });
  }

  /**
   * Fire-and-forget (activate-result).
   * @param {Record<string, unknown>} msg
   */
  post(msg) {
    if (!this.connected || !this.port) {
      throw new Error('native-port-disconnected');
    }
    this.port.postMessage(msg);
  }

  get isConnected() {
    return this.connected;
  }

  get reconnectAttempts() {
    return this.attempt;
  }

  // --- private ---

  #connect() {
    if (this.stopped) return;

    try {
      const port = this.runtime.connectNative(this.hostName);
      this.port = port;

      const onMsg = (msg) => {
        this.#onPortMessage(msg);
      };
      const onDisc = () => {
        this.#handleDisconnect('port-disconnect');
      };

      port.onMessage.addListener(onMsg);
      port.onDisconnect.addListener(onDisc);

      // Chrome sets lastError on failed connect when first message/disconnect fires.
      const err = this.runtime.lastError;
      if (err?.message) {
        this.log.warn('native-connect-error', { reason: 'lastError', host: this.hostName });
        this.#handleDisconnect('connect-error');
        return;
      }

      this.connected = true;
      this.attempt = 0;
      this.log.info('native-connected', { host: this.hostName });
      this.onConnectionChange(true, { host: this.hostName });
    } catch (err) {
      this.log.warn('native-connect-throw', { reason: err?.name || 'error' });
      this.#scheduleReconnect();
    }
  }

  /**
   * @param {unknown} msg
   */
  #onPortMessage(msg) {
    // Resolve pending request if requestId matches a result.
    if (msg && typeof msg === 'object') {
      const rec = /** @type {Record<string, unknown>} */ (msg);
      const rid = typeof rec.requestId === 'string' ? rec.requestId : '';
      if (rid && this._pending.has(rid)) {
        const pending = this._pending.get(rid);
        this._pending.delete(rid);
        if (pending) {
          this.clearSchedule(pending.timer);
          pending.resolve(msg);
        }
      }
    }

    try {
      const ret = this.onMessage(msg);
      if (ret && typeof ret.then === 'function') {
        ret.catch((err) => {
          this.log.error('native-onmessage-error', { reason: err?.name || 'error' });
        });
      }
    } catch (err) {
      this.log.error('native-onmessage-throw', { reason: err?.name || 'error' });
    }
  }

  /**
   * @param {string} reason
   */
  #handleDisconnect(reason) {
    if (this.port) {
      this.port = null;
    }
    const wasConnected = this.connected;
    this.connected = false;
    this.#rejectAllPending(reason);

    if (wasConnected) {
      this.log.warn('native-disconnected', { reason });
      this.onConnectionChange(false, { reason });
    }

    if (!this.stopped) {
      this.#scheduleReconnect();
    }
  }

  #scheduleReconnect() {
    if (this.stopped) return;
    if (this._reconnectTimer != null) return;

    this.attempt += 1;
    const exp = Math.min(
      this.reconnectMaxMs,
      this.reconnectBaseMs * 2 ** Math.min(this.attempt - 1, 6),
    );
    // Jitter ±20%
    const jitter = exp * (0.8 + Math.random() * 0.4);

    this.log.info('native-reconnect-scheduled', {
      attempt: this.attempt,
      delayMs: Math.round(jitter),
    });

    this._reconnectTimer = this.schedule(() => {
      this._reconnectTimer = null;
      this.#connect();
    }, jitter);
  }

  /**
   * @param {string} reason
   */
  #rejectAllPending(reason) {
    for (const [id, pending] of this._pending) {
      this.clearSchedule(pending.timer);
      pending.reject(new Error(reason));
      this._pending.delete(id);
    }
  }
}

/**
 * Pure reconnect state helper for unit tests (no timers).
 */
export class ReconnectPolicy {
  /**
   * @param {{ baseMs?: number, maxMs?: number }} [opts]
   */
  constructor(opts = {}) {
    this.baseMs = opts.baseMs ?? 500;
    this.maxMs = opts.maxMs ?? 15_000;
    this.attempt = 0;
  }

  nextDelayMs() {
    this.attempt += 1;
    return Math.min(this.maxMs, this.baseMs * 2 ** Math.min(this.attempt - 1, 6));
  }

  reset() {
    this.attempt = 0;
  }
}
