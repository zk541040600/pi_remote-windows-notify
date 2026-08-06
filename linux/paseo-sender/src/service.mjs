import { performance } from "node:perf_hooks";
import { DaemonAdapter } from "./daemon.mjs";
import { WindowsDelivery, nextBackoffMs } from "./delivery.mjs";
import { HealthLeaseOwner } from "./lease.mjs";
import {
  agentDisplayName,
  normalizeAttentionEvent,
  extractPermissionRequestIds,
  validateRoute,
} from "./normalize.mjs";
import { agentKey, createLogger, fingerprint } from "./privacy.mjs";
import { Reconciler } from "./reconcile.mjs";
import { DurableStore } from "./store.mjs";

const DESKTOP_LIFETIME_MS = 30 * 60 * 1000;
const PUMP_INTERVAL_MS = 500;
const STOP_WAIT_MS = 5000;
const MAX_DISPLAY_NAMES = 4096;
/** Bounded full-reconcile retry after unresolved authority (no hot loop). */
const RECONCILE_RETRY_MS = 5_000;
const MAX_RECONCILE_RETRY_MS = 60_000;

/** Provider-independent sender service lifecycle. */
export class PaseoSenderService {
  /**
   * @param {{ config: import("./config.mjs").SenderConfig, store?: DurableStore, delivery?: WindowsDelivery, daemon?: DaemonAdapter, lease?: HealthLeaseOwner, logger?: ReturnType<typeof createLogger>, DaemonClientImpl?: any, fetchImpl?: typeof fetch, now?: () => number }} options
   */
  constructor(options) {
    this.config = options.config;
    this.logger = options.logger || createLogger();
    this.now = options.now || (() => Date.now());
    this.stopWaitMs = options.stopWaitMs ?? STOP_WAIT_MS;
    this.store = options.store || new DurableStore(this.config.stateDir, { logger: this.logger, now: this.now });
    this.delivery = options.delivery || new WindowsDelivery({
      notifyUrl: this.config.windowsEndpoint,
      token: this.config.windowsToken,
      timeoutMs: this.config.timeoutMs,
      deliveryMode: this.config.deliveryMode,
      fetchImpl: options.fetchImpl,
      logger: this.logger,
    });
    this.daemon = options.daemon || new DaemonAdapter({
      url: this.config.daemonUrl,
      clientId: this.config.clientId,
      password: this.config.daemonPassword,
      DaemonClientImpl: options.DaemonClientImpl,
      logger: this.logger,
    });
    this.lease = options.lease || new HealthLeaseOwner({
      stateDir: this.config.stateDir,
      staleMs: this.config.leaseStaleMs,
      logger: this.logger,
      now: this.now,
    });
    this.reconciler = new Reconciler({
      store: this.store,
      logger: this.logger,
      finishedTtlMs: this.config.finishedTtlMs,
      now: this.now,
    });

    this.running = false;
    this.stopping = false;
    this.inFlightAgents = new Set();
    this.inFlightAuthority = new Set();
    this.globalInFlight = 0;
    this.healthTimer = null;
    this.pumpTimer = null;
    this.reconcileRetryTimer = null;
    this.reconcileRetryAttempts = 0;
    this.stopPromise = null;
    this.reconcilePromise = null;
    /** When true, exactly one later reconcile pass runs after the current pass finishes. */
    this.reconcilePendingRerun = false;
    this.authorityReady = false;
    this.eventUnsubscribers = [];
    /**
     * Ephemeral agentKey -> sanitized snapshot title/fallback.
     * Never persisted in state/outbox/WAL/logs.
     * @type {Map<string, string>}
     */
    this.agentDisplayNames = new Map();
  }

  async start() {
    if (this.running) return { started: true, reason: "already-running" };
    this.stopping = false;
    const loaded = await this.store.load();
    await this.lease.load();
    if (!loaded.ok) {
      this.logger.error("service_blocked_corrupt_store", { reason: loaded.reason });
      return { started: false, reason: "store-blocked" };
    }
    if (!this.config.enabled) {
      this.logger.warn("service_disabled", {});
      return { started: false, reason: "disabled" };
    }

    this.running = true;
    this.#wireEvents();
    try {
      await this.daemon.connect();
      await this.#requestReconcile();
      if (this.stopping) {
        this.running = false;
        return { started: false, reason: "stopped-during-start" };
      }
    } catch (error) {
      this.running = false;
      await this.#unwireAndCloseDaemon();
      throw error;
    }

    this.healthTimer = setInterval(() => {
      void this.#guard("health_tick_failed", () => this.#healthTick());
    }, this.config.healthIntervalMs);
    this.healthTimer.unref?.();
    this.pumpTimer = setInterval(() => {
      void this.#guard("pump_failed", () => this.#pump());
    }, PUMP_INTERVAL_MS);
    this.pumpTimer.unref?.();

    await this.#healthTick();
    await this.#pump();
    this.logger.info("service_started", {
      deliveryMode: this.config.deliveryMode,
      stateFp: fingerprint(this.config.stateDir),
    });
    return { started: true };
  }

  stop() {
    if (this.stopPromise) return this.stopPromise;
    this.stopPromise = this.#stopOnce();
    return this.stopPromise;
  }

  async #stopOnce() {
    this.stopping = true;
    if (this.healthTimer) clearInterval(this.healthTimer);
    if (this.pumpTimer) clearInterval(this.pumpTimer);
    if (this.reconcileRetryTimer) clearTimeout(this.reconcileRetryTimer);
    this.healthTimer = null;
    this.pumpTimer = null;
    this.reconcileRetryTimer = null;
    this.reconcilePendingRerun = false;
    this.delivery.abortAll?.();

    const deadline = performance.now() + this.stopWaitMs;
    while ((this.globalInFlight > 0 || this.reconcilePromise) && performance.now() < deadline) {
      await sleep(25);
    }
    const remainingMs = Math.max(0, deadline - performance.now());
    if (remainingMs > 0) {
      await Promise.race([this.store.whenIdle(), sleep(remainingMs)]);
    }
    await Promise.race([this.#unwireAndCloseDaemon(), sleep(2000)]);
    this.running = false;
    this.logger.info("service_stopped", { inFlightRemaining: this.globalInFlight });
  }

  #wireEvents() {
    this.eventUnsubscribers.push(
      this.daemon.onAgentAttentionRequired((notification) =>
        this.#guard("attention_handler_failed", () => this.#onAttention(notification))),
      this.daemon.subscribeLifecycle((event) =>
        this.#guard("lifecycle_handler_failed", () => this.#onLifecycle(event))),
    );
    if (typeof this.daemon.subscribeConnectionStatus === "function") {
      this.eventUnsubscribers.push(
        this.daemon.subscribeConnectionStatus((status) => {
          if (status?.status === "connected") return this.#requestReconcile();
          this.authorityReady = false;
          return undefined;
        }),
      );
    }
  }

  async #unwireAndCloseDaemon() {
    for (const stop of this.eventUnsubscribers.splice(0)) {
      try { stop?.(); } catch { /* best-effort callback cleanup */ }
    }
    await this.daemon.close();
  }

  /**
   * Coalescing reconcile request: at most one active pass.
   * A signal arriving mid-pass schedules exactly one later rerun.
   */
  #requestReconcile() {
    if (this.stopping) return Promise.resolve();
    if (this.reconcilePromise) {
      this.reconcilePendingRerun = true;
      return this.reconcilePromise;
    }
    this.reconcilePromise = this.#reconcileNow()
      .catch((error) => {
        this.logger.warn("reconcile_failed", { reason: error instanceof Error ? error.name : "error" });
        this.authorityReady = false;
        this.#scheduleReconcileRetry();
      })
      .finally(() => {
        this.reconcilePromise = null;
        if (this.reconcilePendingRerun && !this.stopping) {
          this.reconcilePendingRerun = false;
          void this.#requestReconcile();
        }
      });
    return this.reconcilePromise;
  }

  async #reconcileNow() {
    this.authorityReady = false;
    if (!this.daemon.isConnected() || this.store.isLiveDeliveryBlocked()) {
      this.#scheduleReconcileRetry();
      return;
    }
    const serverIdAtStart = this.daemon.getServerId();
    if (!serverIdAtStart) {
      this.#scheduleReconcileRetry();
      return;
    }

    let agents;
    let workspaces;
    try {
      [agents, workspaces] = await Promise.all([
        this.daemon.fetchAllAgents(),
        this.daemon.fetchAllWorkspaces(),
      ]);
    } catch (error) {
      this.logger.warn("reconcile_fetch_failed", { reason: error instanceof Error ? error.name : "error" });
      this.authorityReady = false;
      this.#scheduleReconcileRetry();
      return;
    }

    // Stop never applies a snapshot that completed after shutdown began.
    if (this.stopping) return;

    // Discard a completed snapshot if disconnected/serverId changed during fetch.
    if (!this.daemon.isConnected()) {
      this.logger.warn("reconcile_discarded", { reason: "disconnected-during-fetch" });
      this.authorityReady = false;
      this.#scheduleReconcileRetry();
      return;
    }
    const serverIdNow = this.daemon.getServerId();
    if (!serverIdNow || serverIdNow !== serverIdAtStart) {
      this.logger.warn("reconcile_discarded", { reason: "server-changed-during-fetch" });
      this.authorityReady = false;
      // Rerun for the current connection identity.
      this.reconcilePendingRerun = true;
      return;
    }

    const result = await this.reconciler.reconcile({
      serverId: serverIdNow,
      agents,
      workspaces,
      workspaceIds: new Set(workspaces.map((workspace) => workspace.id)),
      isFirstRun: !this.store.state.initialized,
      pruneMissing: true,
    });

    // Replace display names for this server snapshot; drop deleted agents.
    this.#applyDisplayNames(serverIdNow, result.displayNames, result.seenKeys);

    if (result.unresolved > 0) {
      this.authorityReady = false;
      this.logger.warn("reconcile_unresolved", {
        unresolved: result.unresolved,
        unresolvedPermissions: result.unresolvedPermissions,
        unresolvedFinished: result.unresolvedFinished,
      });
      this.#scheduleReconcileRetry();
    } else {
      this.authorityReady = true;
      this.reconcileRetryAttempts = 0;
      this.#clearReconcileRetry();
    }
    await this.#pump();
  }

  #scheduleReconcileRetry() {
    if (this.stopping || this.reconcileRetryTimer) return;
    const delay = Math.min(
      MAX_RECONCILE_RETRY_MS,
      RECONCILE_RETRY_MS * 2 ** Math.min(6, this.reconcileRetryAttempts),
    );
    this.reconcileRetryAttempts += 1;
    this.reconcileRetryTimer = setTimeout(() => {
      this.reconcileRetryTimer = null;
      if (!this.stopping) void this.#requestReconcile();
    }, delay);
    this.reconcileRetryTimer.unref?.();
  }

  #clearReconcileRetry() {
    if (this.reconcileRetryTimer) {
      clearTimeout(this.reconcileRetryTimer);
      this.reconcileRetryTimer = null;
    }
  }

  /**
   * @param {string} serverId
   * @param {Map<string, string>} names
   * @param {Set<string>} seenKeys
   */
  #applyDisplayNames(serverId, names, seenKeys) {
    for (const [key, name] of names) {
      this.agentDisplayNames.set(key, name);
    }
    // Remove entries for agents missing from this server's snapshot.
    for (const key of [...this.agentDisplayNames.keys()]) {
      // Only prune keys belonging to the current server that are no longer seen.
      // Foreign-server keys stay until their own reconcile/delete path removes them.
      if (seenKeys && !seenKeys.has(key)) {
        // Check whether this key still has an outbox/pending item for another server.
        const item = this.store.getItem(key);
        const pending = this.store.listPendingAuthority().some(
          (entry) => agentKey({ serverId: entry.serverId, agentId: entry.agentId }) === key
            && entry.serverId !== serverId,
        );
        if ((!item || item.serverId === serverId) && !pending) {
          this.agentDisplayNames.delete(key);
        }
      }
    }
    while (this.agentDisplayNames.size > MAX_DISPLAY_NAMES) {
      const oldest = this.agentDisplayNames.keys().next().value;
      this.agentDisplayNames.delete(oldest);
    }
  }

  /** Remember a single agent display name from an authority fetch. Never persists. */
  #rememberDisplayName(serverId, agentId, agent) {
    const key = agentKey({ serverId, agentId });
    this.agentDisplayNames.set(key, agentDisplayName(agent, this.config.agentDisplayNameFallback || "Agent"));
    while (this.agentDisplayNames.size > MAX_DISPLAY_NAMES) {
      const oldest = this.agentDisplayNames.keys().next().value;
      this.agentDisplayNames.delete(oldest);
    }
  }

  #forgetDisplayName(serverId, agentId) {
    this.agentDisplayNames.delete(agentKey({ serverId, agentId }));
  }

  /**
   * Resolve ephemeral display name. Returns null when unknown (block delivery until
   * reconciliation/authority repopulates). Fixed "Agent" fallback counts as known.
   * @param {{ serverId: string, agentId: string }} item
   * @returns {string | null}
   */
  #displayNameFor(item) {
    const key = agentKey({ serverId: item.serverId, agentId: item.agentId });
    if (this.agentDisplayNames.has(key)) return this.agentDisplayNames.get(key) || "Agent";
    return null;
  }

  async #onAttention(notification) {
    if (this.stopping || this.store.isLiveDeliveryBlocked()) return;
    const serverId = this.daemon.getServerId();
    if (!serverId) {
      this.logger.warn("attention_unbound", { reason: "server-info-missing" });
      return;
    }
    const normalized = normalizeAttentionEvent(notification, { serverId, now: this.now() });
    if (!normalized.ok) {
      if (normalized.reason !== "error") this.logger.info("attention_drop", { reason: normalized.reason });
      return;
    }
    const event = { ...normalized, serverId };
    const recorded = await this.reconciler.recordAttention(event);
    if (recorded.reason === "processed") return;
    await this.#attemptAuthority(normalized.eventFp);
  }

  async #onLifecycle(event) {
    if (this.stopping || this.store.isLiveDeliveryBlocked()) return;
    const serverId = this.daemon.getServerId();
    if (!serverId || typeof event?.agentId !== "string") return;

    if (event.type === "agent_deleted") {
      await this.reconciler.handleAgentDeleted(serverId, event.agentId);
      this.#forgetDisplayName(serverId, event.agentId);
      await this.#pump();
      return;
    }
    if (event.type === "agent_permission_resolved" && typeof event.requestId === "string") {
      await this.reconciler.handlePermissionResolved(serverId, event.agentId, event.requestId);
      await this.#pump();
      return;
    }
    if (event.type === "agent_permission_request" && typeof event.request?.id === "string") {
      // Correlation only: never creates a popup.
      await this.reconciler.handlePermissionRequest(serverId, event.agentId, event.request.id);
      for (const pending of this.store.listPendingAuthority()) {
        if (pending.serverId === serverId && pending.agentId === event.agentId && pending.reason === "permission") {
          await this.reconciler.scheduleAuthorityRetry(pending.eventFp, {
            attempts: pending.attempts,
            nextAttemptAt: this.now(),
            lastError: "correlation-update",
          });
          await this.#attemptAuthority(pending.eventFp);
        }
      }
    }
  }

  async #attemptAuthority(eventFp) {
    if (
      this.inFlightAuthority.has(eventFp) ||
      this.stopping ||
      this.globalInFlight >= this.config.globalConcurrency
    ) return;
    const pending = this.store.getPendingAuthority(eventFp);
    if (!pending || pending.nextAttemptAt > this.now()) return;

    // Never resolve pending-authority items against a different daemon identity.
    const connectedServerId = this.daemon.getServerId();
    if (!this.daemon.isConnected() || !connectedServerId) return;
    if (pending.serverId !== connectedServerId) {
      this.logger.warn("attention_authority_server_mismatch", {
        eventFp: fingerprint(eventFp),
        reason: "foreign-server",
      });
      // Preserve safely; do not combine new snapshots with old server IDs.
      return;
    }

    this.inFlightAuthority.add(eventFp);
    this.globalInFlight += 1;
    try {
      const result = await this.daemon.fetchAgent(pending.agentId);
      if (this.stopping) throw new AuthorityError("stopping");
      const agent = result?.agent;
      if (!agent || agent.id !== pending.agentId) throw new AuthorityError("agent-unavailable");

      // Re-check connection identity after the RPC.
      if (!this.daemon.isConnected() || this.daemon.getServerId() !== pending.serverId) {
        throw new AuthorityError("server-changed");
      }

      const workspaceId = typeof agent.workspaceId === "string" ? agent.workspaceId : "";
      const workspace = workspaceId ? await this.daemon.fetchWorkspace(workspaceId) : null;
      if (this.stopping) throw new AuthorityError("stopping");
      if (!workspace || workspace.id !== workspaceId) throw new AuthorityError("workspace-unavailable");

      // Workspace pagination is a second RPC boundary; bind it to the same daemon identity too.
      if (!this.daemon.isConnected() || this.daemon.getServerId() !== pending.serverId) {
        throw new AuthorityError("server-changed");
      }
      const route = validateRoute({ serverId: pending.serverId, workspaceId, agentId: pending.agentId });
      if (!route.ok) throw new AuthorityError("route-invalid");
      const permissionRequestIds = pending.reason === "permission"
        ? this.store.permissionIdsForTriggeredAttention(
            pending.serverId,
            pending.agentId,
            extractPermissionRequestIds(agent.pendingPermissions),
          )
        : [];
      if (pending.reason === "permission" && permissionRequestIds.length === 0) {
        throw new AuthorityError("permission-ids-pending");
      }

      this.#rememberDisplayName(pending.serverId, pending.agentId, agent);

      await this.reconciler.resolveAttention({
        eventFp,
        workspaceId: route.workspaceId,
        permissionRequestIds,
      });
      await this.#pump();
    } catch (error) {
      const current = this.store.getPendingAuthority(eventFp);
      if (current && !this.stopping && !this.store.isLiveDeliveryBlocked()) {
        const attempts = current.attempts + 1;
        await this.reconciler.scheduleAuthorityRetry(eventFp, {
          attempts,
          nextAttemptAt: this.now() + nextBackoffMs(attempts - 1, {
            initialMs: this.config.backoffInitialMs,
            maxMs: this.config.backoffMaxMs,
          }),
          lastError: error instanceof AuthorityError ? error.code : "authority-rpc",
        });
      }
      if (!this.stopping) {
        this.logger.warn("attention_authority_retry", {
          eventFp: fingerprint(eventFp),
          reason: error instanceof AuthorityError ? error.code : "authority-rpc",
        });
      }
    } finally {
      this.inFlightAuthority.delete(eventFp);
      this.globalInFlight -= 1;
    }
  }

  async #healthTick() {
    if (
      this.stopping ||
      !this.running ||
      !this.config.enabled ||
      this.config.deliveryMode !== "live" ||
      this.store.isLiveDeliveryBlocked() ||
      !this.authorityReady ||
      this.store.listPendingAuthority().length > 0
    ) return;
    const daemonOk = this.daemon.isConnected();
    const serverId = this.daemon.getServerId();
    const windowsHealth = daemonOk && serverId && this.config.windowsToken
      ? await this.delivery.probeHealth()
      : { ok: false, ready: false, reason: "prerequisite" };
    await this.lease.refresh({ daemonConnected: daemonOk, serverId, windowsHealth });
  }

  async #pump() {
    if (this.stopping || this.store.isLiveDeliveryBlocked()) return;
    const now = this.now();
    const connectedServerId = this.daemon.isConnected() ? this.daemon.getServerId() : null;
    for (const pending of this.store.listPendingAuthority()) {
      // Only attempt authority for the currently connected server.
      if (connectedServerId && pending.serverId === connectedServerId && pending.nextAttemptAt <= now) {
        void this.#attemptAuthority(pending.eventFp);
      }
    }
    if (!this.config.enabled || this.config.deliveryMode !== "live") return;

    const items = this.store.listItems()
      .filter((item) => {
        if (item.status === "terminal" || item.status === "invalid") return false;
        if (item.status === "delivered" && item.kind === "permission") {
          return item.desktopShownAt !== undefined && now - item.desktopShownAt >= DESKTOP_LIFETIME_MS;
        }
        return (item.status === "closing" || item.status === "pending") && item.nextAttemptAt <= now;
      })
      .sort((left, right) => left.nextAttemptAt - right.nextAttemptAt);

    for (const item of items) {
      if (this.globalInFlight >= this.config.globalConcurrency) break;
      if (this.inFlightAgents.has(item.agentKey)) continue;
      // After restart, wait until reconciliation/authority repopulates a display name.
      if (item.status === "pending" && this.#displayNameFor(item) === null) continue;
      if (item.kind === "finished" && item.deadlineMs && now > item.deadlineMs) {
        await this.store.transaction(() => {
          const current = this.store.getItem(item.agentKey);
          if (current) {
            current.status = "terminal";
            current.lastResult = "expired";
            current.updatedAt = now;
          }
        });
        continue;
      }
      this.inFlightAgents.add(item.agentKey);
      this.globalInFlight += 1;
      void this.deliverOne(item).catch(() => {
        this.logger.error("delivery_task_failed", { agentFp: fingerprint(item.agentId) });
      }).finally(() => {
        this.inFlightAgents.delete(item.agentKey);
        this.globalInFlight -= 1;
      });
    }
  }

  async deliverOne(item) {
    const now = this.now();
    if (
      item.status === "delivered" && item.kind === "permission" &&
      item.desktopShownAt !== undefined && now - item.desktopShownAt >= DESKTOP_LIFETIME_MS
    ) {
      await this.store.transaction(() => {
        const current = this.store.getItem(item.agentKey);
        if (current?.status === "delivered" && current.kind === "permission") {
          current.status = "pending";
          current.nextAttemptAt = now;
          delete current.desktopShownAt;
          current.updatedAt = now;
        }
      });
      item = this.store.getItem(item.agentKey) || item;
    }
    if (item.status === "closing") return this.closeOne(item);

    // Block notify until we have a display name (ephemeral map populated by reconcile/authority).
    const displayName = this.#displayNameFor(item);
    if (displayName === null && item.status === "pending") {
      return;
    }

    if (item.supersededNotificationId) {
      const oldNotificationId = item.supersededNotificationId;
      const closeResult = await this.delivery.close(oldNotificationId);
      let mayNotify = false;
      await this.store.transaction(() => {
        const current = this.store.getItem(item.agentKey);
        if (!current || current.notificationId !== item.notificationId) return;
        current.attempts += 1;
        current.lastResult = this.#safeResultCode(`superseded-${closeResult.code}`);
        current.updatedAt = this.now();
        if (closeResult.code === "ok") {
          delete current.supersededNotificationId;
          current.attempts = 0;
          mayNotify = true;
        } else if (closeResult.code === "invalid") {
          current.status = "invalid";
          current.errorCode = "superseded-close-invalid";
        } else {
          // auth/retry/transport: retain and backoff
          current.status = "pending";
          current.nextAttemptAt = this.now() + this.#retryDelay(current.attempts);
          if (closeResult.code === "auth") {
            this.logger.warn("close_auth_failure", {
              notificationFp: fingerprint(oldNotificationId),
              attempts: current.attempts,
            });
          }
        }
      });
      if (!mayNotify) return;
      item = this.store.getItem(item.agentKey) || item;
    }

    const result = await this.delivery.notify(item, {
      agentDisplayName: displayName || this.config.agentDisplayNameFallback || "Agent",
      detailedSummary: this.config.detailedSummary,
      titleMax: this.config.titleMaxCodePoints,
      bodyMax: this.config.bodyMaxCodePoints,
    });
    await this.store.transaction(() => {
      const current = this.store.getItem(item.agentKey);
      if (!current || current.notificationId !== item.notificationId) return;
      current.attempts += 1;
      current.lastResult = this.#safeResultCode(result.code);
      current.updatedAt = this.now();
      if (result.code === "ok" || result.code === "dedup") {
        if (current.kind === "finished") {
          this.store.setWatermark(current.serverId, current.agentId, current.eventTimestamp);
          this.store.removeItem(current.agentKey);
        } else {
          current.status = "delivered";
          current.desktopShownAt = this.now();
        }
        return;
      }
      if (result.code === "suppressed-active-agent" && current.kind === "finished") {
        this.store.setWatermark(current.serverId, current.agentId, current.eventTimestamp);
        this.store.removeItem(current.agentKey);
        return;
      }
      if (result.code === "invalid") {
        current.status = "invalid";
        current.errorCode = "contract-invalid";
        this.logger.error("notify_invalid", {
          kind: current.kind,
          notificationFp: fingerprint(current.notificationId),
          attempts: current.attempts,
        });
        return;
      }
      // auth / retry / transport / suppressed-permission: retain with bounded backoff
      current.status = "pending";
      current.nextAttemptAt = this.now() + this.#retryDelay(current.attempts);
      if (result.code === "auth") {
        this.logger.warn("notify_auth_failure", {
          kind: current.kind,
          notificationFp: fingerprint(current.notificationId),
          attempts: current.attempts,
        });
      }
    });
  }

  async closeOne(item) {
    const result = await this.delivery.close(item.notificationId);
    await this.store.transaction(() => {
      const current = this.store.getItem(item.agentKey);
      if (!current || current.notificationId !== item.notificationId) return;
      current.attempts += 1;
      current.lastResult = this.#safeResultCode(result.code);
      current.updatedAt = this.now();
      if (result.code === "ok") {
        this.store.removeItem(current.agentKey);
        return;
      }
      if (result.code === "invalid") {
        current.status = "invalid";
        current.errorCode = "close-invalid";
        this.logger.error("close_invalid", { notificationFp: fingerprint(current.notificationId) });
        return;
      }
      // auth / retry / transport: retain close item
      current.status = "closing";
      current.nextAttemptAt = this.now() + this.#retryDelay(current.attempts);
      if (result.code === "auth") {
        this.logger.warn("close_auth_failure", {
          notificationFp: fingerprint(current.notificationId),
          attempts: current.attempts,
        });
      }
    });
  }

  /** lastResult / errorCode must match the store SAFE_CODE_RE. */
  #safeResultCode(code) {
    const value = String(code || "unknown").toLowerCase().replace(/[^a-z0-9-]/gu, "-").slice(0, 64);
    return value || "unknown";
  }

  #retryDelay(completedAttempts) {
    return nextBackoffMs(Math.max(0, completedAttempts - 1), {
      initialMs: this.config.backoffInitialMs,
      maxMs: this.config.backoffMaxMs,
    });
  }

  async #guard(event, operation) {
    try {
      return await operation();
    } catch (error) {
      this.logger.error(event, { reason: error instanceof Error ? error.name : "error" });
      return undefined;
    }
  }

  getStatus() {
    const daemonConnected = this.running && this.daemon.isConnected();
    const serverId = daemonConnected ? this.daemon.getServerId() : null;
    return {
      running: this.running,
      deliveryMode: this.config.deliveryMode,
      enabled: this.config.enabled,
      storeCorrupt: this.store.corrupt,
      initialized: this.store.state.initialized,
      outboxCount: this.store.listItems().length,
      pendingAuthorityCount: this.store.listPendingAuthority().length,
      authorityReady: this.authorityReady,
      leaseHealthy: this.lease.isHealthy(),
      daemonConnected,
      serverFp: serverId ? fingerprint(serverId) : null,
      displayNameCount: this.agentDisplayNames.size,
    };
  }
}

class AuthorityError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export { DESKTOP_LIFETIME_MS, RECONCILE_RETRY_MS, MAX_RECONCILE_RETRY_MS };
