import { buildClosePayload, buildNotifyPayload, validateRoute } from "./normalize.mjs";
import { createLogger, fingerprint } from "./privacy.mjs";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const HEALTH_FIELDS = [
  "version",
  "ready",
  "listenerReady",
  "displayReady",
  "routeReady",
  "routeState",
  "capabilities",
];
const CAPABILITY_FIELDS = ["notifyV1", "closeV1", "existingClickEventV1"];
const ROUTE_STATES = new Set([
  "ready",
  "app-absent",
  "disabled",
  "config-invalid",
  "controller-missing",
  "controller-error",
  "executable-missing",
  "flags-mismatch",
  "probe-error",
  "owner-ready",
  "non-loopback",
  "foreign-owner",
  "ambiguous",
  "malformed",
  "cdp-unavailable",
  "target-missing",
]);

/**
 * @typedef {"ok" | "dedup" | "suppressed-active-agent" | "retry" | "invalid" | "transport" | "auth"} DeliveryResultCode
 */

/**
 * @typedef {object} DeliveryResult
 * @property {DeliveryResultCode} code
 * @property {number} status
 * @property {number} elapsedMs
 * @property {string} [body]
 */

/**
 * Classify Windows bridge response body / HTTP status.
 * @param {number} status
 * @param {string} bodyText
 * @returns {DeliveryResultCode}
 */
export function classifyNotifyResponse(status, bodyText) {
  // Auth/config failures must retain durable items; only body/shape invalid terminalizes.
  if (status === 403 || status === 401) return "auth";
  if (status === 404) return "retry";
  if (status >= 500) return "retry";
  if (status === 408 || status === 429) return "retry";
  if (status !== 200) {
    // Other 4xx => invalid contract
    if (status >= 400 && status < 500) return "invalid";
    return "retry";
  }
  const body = (bodyText || "").trim().toLowerCase();
  if (body === "ok") return "ok";
  if (body === "dedup") return "dedup";
  if (body === "suppressed-active-agent") return "suppressed-active-agent";
  if (body === "retry") return "retry";
  if (body === "invalid") return "invalid";
  // Unknown 200 body treated as retry (transient bridge drift) rather than silent ok
  return "retry";
}

/**
 * Classify close response.
 * @param {number} status
 * @param {string} bodyText
 */
export function classifyCloseResponse(status, bodyText) {
  if (status === 403 || status === 401) return "auth";
  if (status >= 500 || status === 408 || status === 429 || status === 404) return "retry";
  if (status !== 200) {
    if (status >= 400 && status < 500) return "invalid";
    return "retry";
  }
  const body = (bodyText || "").trim().toLowerCase();
  if (body === "ok") return "ok";
  if (body === "invalid") return "invalid";
  if (body === "retry") return "retry";
  return "retry";
}

/**
 * Exponential backoff with bounded jitter.
 * @param {number} attempts 0-based completed attempts
 * @param {{ initialMs?: number, maxMs?: number, jitterRatio?: number, random?: () => number }} [options]
 */
export function nextBackoffMs(attempts, options = {}) {
  const initial = options.initialMs ?? 1000;
  const max = options.maxMs ?? 60000;
  const jitterRatio = options.jitterRatio ?? 0.2;
  const random = options.random ?? Math.random;
  const exp = Math.min(max, initial * 2 ** Math.max(0, attempts));
  const jitter = exp * jitterRatio * (random() * 2 - 1);
  return Math.max(initial, Math.min(max, Math.round(exp + jitter)));
}

/**
 * Windows delivery client for /notify and /paseo/close.
 */
export class WindowsDelivery {
  /**
   * @param {{
   *   notifyUrl: string,
   *   token: string,
   *   timeoutMs: number,
   *   deliveryMode: "shadow" | "live",
   *   fetchImpl?: typeof fetch,
   *   logger?: ReturnType<typeof createLogger>,
   * }} options
   */
  constructor(options) {
    this.notifyUrl = options.notifyUrl;
    this.token = options.token;
    this.timeoutMs = options.timeoutMs;
    this.deliveryMode = options.deliveryMode;
    this.fetchImpl = options.fetchImpl || globalThis.fetch.bind(globalThis);
    this.logger = options.logger || createLogger();
    this.controllers = new Set();
  }

  healthUrl() {
    return replacePath(this.notifyUrl, "/paseo/health");
  }

  closeUrl() {
    return replacePath(this.notifyUrl, "/paseo/close");
  }

  /**
   * @param {import("./store.mjs").OutboxItem} item
   * @param {{ detailedSummary?: boolean, summaryText?: string, titleMax?: number, bodyMax?: number }} [display]
   * @returns {Promise<DeliveryResult>}
   */
  async notify(item, display = {}) {
    const valid = validateDeliveryItem(item);
    if (!valid.ok) {
      this.logger.error("notify_item_invalid", {
        reason: valid.reason,
        notificationFp: fingerprint(item?.notificationId || ""),
      });
      return { code: "invalid", status: 0, elapsedMs: 0, body: "invalid-local-item" };
    }
    const payload = buildNotifyPayload({
      notificationId: item.notificationId,
      kind: item.kind,
      serverId: item.serverId,
      workspaceId: item.workspaceId,
      agentId: item.agentId,
      agentDisplayName: display.agentDisplayName,
      detailedSummary: display.detailedSummary,
      summaryText: display.summaryText,
      titleMax: display.titleMax,
      bodyMax: display.bodyMax,
    });

    if (this.deliveryMode !== "live") {
      this.logger.info("notify_shadow", {
        kind: item.kind,
        notificationFp: fingerprint(item.notificationId),
        agentFp: fingerprint(item.agentId),
      });
      return { code: "ok", status: 200, elapsedMs: 0, body: "ok" };
    }

    return this.#postJson(this.notifyUrl, payload, classifyNotifyResponse, "notify");
  }

  /**
   * @param {string} notificationId
   * @returns {Promise<DeliveryResult>}
   */
  async close(notificationId) {
    if (!UUID_RE.test(notificationId || "")) {
      return { code: "invalid", status: 0, elapsedMs: 0, body: "invalid-local-id" };
    }
    const payload = buildClosePayload(notificationId);
    if (this.deliveryMode !== "live") {
      this.logger.info("close_shadow", {
        notificationFp: fingerprint(notificationId),
      });
      return { code: "ok", status: 200, elapsedMs: 0, body: "ok" };
    }
    return this.#postJson(this.closeUrl(), payload, classifyCloseResponse, "close");
  }

  /**
   * Authenticated health probe. Never uses GET /health.
   * @returns {Promise<{ ok: boolean, ready: boolean, elapsedMs: number, reason?: string, snapshot?: object }>}
   */
  async probeHealth() {
    const started = Date.now();
    if (this.deliveryMode === "shadow" && !this.token) {
      // In pure offline shadow without token, health cannot pass — intentional.
    }
    try {
      const controller = new AbortController();
      this.controllers.add(controller);
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      let response;
      try {
        response = await this.fetchImpl(this.healthUrl(), {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Pi-Notify-Token": this.token,
          },
          body: "{}",
          redirect: "error",
          signal: controller.signal,
        });
      } finally {
        clearTimeout(timer);
        this.controllers.delete(controller);
      }
      const elapsedMs = Date.now() - started;
      if (response.status === 403 || response.status === 401) {
        return { ok: false, ready: false, elapsedMs, reason: "auth" };
      }
      if (!response.ok) {
        return { ok: false, ready: false, elapsedMs, reason: `http-${response.status}` };
      }
      const text = await response.text();
      let snapshot;
      try {
        snapshot = JSON.parse(text);
      } catch {
        return { ok: false, ready: false, elapsedMs, reason: "json" };
      }
      const valid = validateHealthSnapshot(snapshot);
      if (!valid.ok) {
        return { ok: false, ready: false, elapsedMs, reason: valid.reason, snapshot };
      }
      return {
        ok: true,
        ready: snapshot.ready === true,
        elapsedMs,
        snapshot,
      };
    } catch (error) {
      const elapsedMs = Date.now() - started;
      const name = error && /** @type {{ name?: string }} */ (error).name;
      return {
        ok: false,
        ready: false,
        elapsedMs,
        reason: name === "AbortError" ? "timeout" : "transport",
      };
    }
  }

  /**
   * @param {string} url
   * @param {object} payload
   * @param {(status: number, body: string) => string} classifier
   * @param {string} op
   * @returns {Promise<DeliveryResult>}
   */
  async #postJson(url, payload, classifier, op) {
    const started = Date.now();
    try {
      const controller = new AbortController();
      this.controllers.add(controller);
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      let response;
      try {
        response = await this.fetchImpl(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Pi-Notify-Token": this.token,
          },
          body: JSON.stringify(payload),
          redirect: "error",
          signal: controller.signal,
        });
      } finally {
        clearTimeout(timer);
        this.controllers.delete(controller);
      }
      const body = await response.text();
      const elapsedMs = Date.now() - started;
      const code = /** @type {DeliveryResultCode} */ (classifier(response.status, body));
      this.logger.info(`${op}_result`, {
        code,
        status: response.status,
        elapsedMs,
        notificationFp: fingerprint(
          /** @type {{ notificationId?: string }} */ (payload).notificationId || "",
        ),
      });
      return { code, status: response.status, elapsedMs, body: body.trim() };
    } catch (error) {
      const elapsedMs = Date.now() - started;
      const name = error && /** @type {{ name?: string }} */ (error).name;
      this.logger.warn(`${op}_transport`, {
        elapsedMs,
        reason: name === "AbortError" ? "timeout" : "transport",
      });
      return {
        code: "transport",
        status: 0,
        elapsedMs,
        body: name === "AbortError" ? "timeout" : "transport",
      };
    }
  }

  /** Abort all owned HTTP operations during shutdown/reload. */
  abortAll() {
    for (const controller of this.controllers) controller.abort();
    this.controllers.clear();
  }
}

/**
 * Parent contract health schema v1.
 * @param {any} snapshot
 */
export function validateHealthSnapshot(snapshot) {
  if (!isPlainObject(snapshot)) return { ok: false, reason: "shape" };
  if (!hasExactKeys(snapshot, HEALTH_FIELDS)) return { ok: false, reason: "fields" };
  if (snapshot.version !== 1) return { ok: false, reason: "version" };
  for (const field of ["ready", "listenerReady", "displayReady", "routeReady"]) {
    if (typeof snapshot[field] !== "boolean") return { ok: false, reason: field };
  }
  if (typeof snapshot.routeState !== "string" || !ROUTE_STATES.has(snapshot.routeState)) {
    return { ok: false, reason: "routeState" };
  }
  const caps = snapshot.capabilities;
  if (!isPlainObject(caps) || !hasExactKeys(caps, CAPABILITY_FIELDS)) {
    return { ok: false, reason: "capabilities" };
  }
  if (CAPABILITY_FIELDS.some((field) => caps[field] !== true)) {
    return { ok: false, reason: "capabilities-false" };
  }
  const expectedReady = snapshot.listenerReady && snapshot.displayReady && snapshot.routeReady;
  if (snapshot.ready !== expectedReady) return { ok: false, reason: "ready-inconsistent" };
  const expectedRouteReady = snapshot.routeState === "ready" || snapshot.routeState === "app-absent";
  if (snapshot.routeReady !== expectedRouteReady) return { ok: false, reason: "route-inconsistent" };
  return { ok: true };
}

/** Validate recovered/persisted identity immediately before POST. */
export function validateDeliveryItem(item) {
  if (!item || typeof item !== "object") return { ok: false, reason: "shape" };
  if (!UUID_RE.test(item.notificationId || "")) return { ok: false, reason: "notification-id" };
  if (item.kind !== "finished" && item.kind !== "permission") return { ok: false, reason: "kind" };
  const route = validateRoute({
    serverId: item.serverId,
    workspaceId: item.workspaceId,
    agentId: item.agentId,
  });
  if (!route.ok) return { ok: false, reason: route.reason };
  return { ok: true };
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value, keys) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

/**
 * Replace path of notify endpoint with another absolute path on same origin.
 * @param {string} notifyUrl
 * @param {string} absolutePath
 */
export function replacePath(notifyUrl, absolutePath) {
  const url = new URL(notifyUrl);
  url.pathname = absolutePath;
  url.search = "";
  url.hash = "";
  return url.toString();
}
