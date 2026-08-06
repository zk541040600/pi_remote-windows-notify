import { createLogger, fingerprint, normalizeOpaqueId } from "./privacy.mjs";

const DEFAULT_PAGE_LIMIT = 100;
const DEFAULT_MAX_PAGES = 50;

/** Official @getpaseo/client adapter with exact beta.2 cursor contracts. */
export class DaemonAdapter {
  /**
   * @param {{ url: string, clientId: string, password?: string, DaemonClientImpl?: any, logger?: ReturnType<typeof createLogger> }} options
   */
  constructor(options) {
    this.url = options.url;
    this.clientId = options.clientId;
    this.password = options.password;
    this.DaemonClientImpl = options.DaemonClientImpl;
    this.logger = options.logger || createLogger();
    this.client = null;
    this.unsubscribers = [];
    this.attentionHandlers = new Set();
    this.lifecycleHandlers = new Set();
    this.connectionHandlers = new Set();
    this.connected = false;
    this.serverId = null;
  }

  async connect() {
    if (!this.DaemonClientImpl) {
      const mod = await import("@getpaseo/client");
      this.DaemonClientImpl = mod.DaemonClient;
    }
    this.client = new this.DaemonClientImpl({
      url: this.url,
      clientId: this.clientId,
      clientType: "cli",
      appVersion: "paseo-sender/0.1.0",
      password: this.password,
      reconnect: { enabled: true, baseDelayMs: 1500, maxDelayMs: 30000 },
    });

    // Attach all callbacks before connect(), because connect may emit server_info,
    // attention, or connection transitions before its promise resolves.
    this.unsubscribers.push(
      this.client.subscribeConnectionStatus((status) => this.#handleConnection(status)),
      this.client.onAgentAttentionRequired((notification) => {
        this.#emitSafe(this.attentionHandlers, notification, "attention_callback_failed");
      }),
      this.client.subscribe((event) => {
        if (
          event?.type === "agent_permission_request" ||
          event?.type === "agent_permission_resolved" ||
          event?.type === "agent_deleted"
        ) {
          this.#emitSafe(this.lifecycleHandlers, event, "lifecycle_callback_failed");
        }
      }),
    );

    await this.client.connect();
    this.#refreshServerId();
    this.connected = this.client.getConnectionState()?.status === "connected";
    return { connected: this.connected, serverId: this.serverId };
  }

  onAgentAttentionRequired(handler) {
    this.attentionHandlers.add(handler);
    return () => this.attentionHandlers.delete(handler);
  }

  subscribeLifecycle(handler) {
    this.lifecycleHandlers.add(handler);
    return () => this.lifecycleHandlers.delete(handler);
  }

  subscribeConnectionStatus(handler) {
    this.connectionHandlers.add(handler);
    return () => this.connectionHandlers.delete(handler);
  }

  getConnectionState() {
    try {
      return this.client?.getConnectionState?.() || { status: "idle" };
    } catch {
      return { status: "idle" };
    }
  }

  isConnected() {
    this.connected = this.getConnectionState()?.status === "connected";
    if (this.connected) this.#refreshServerId();
    return this.connected && Boolean(this.serverId);
  }

  getServerId() {
    return this.isConnected() ? this.serverId : null;
  }

  /** Fetch and validate one authoritative agent snapshot. */
  async fetchAgent(agentId) {
    const expectedId = requireOpaqueId(agentId, "agentId");
    const result = await this.client.fetchAgent(expectedId);
    if (result === null) return null;
    if (!isPlainObject(result) || !isPlainObject(result.agent)) {
      throw new Error("malformed fetchAgent response");
    }
    if (result.agent.id !== expectedId) throw new Error("fetchAgent identity mismatch");
    return result;
  }

  /**
   * Cursor pagination for exact public FetchAgentsPayload:
   * { entries: [{agent, project}], pageInfo: {nextCursor, prevCursor, hasMore} }.
   */
  async fetchAllAgents(options = {}) {
    const entries = await this.#fetchCursorPages({
      method: "fetchAgents",
      limit: options.limit ?? DEFAULT_PAGE_LIMIT,
      maxPages: options.maxPages ?? DEFAULT_MAX_PAGES,
      baseOptions: {},
      entryValidator(entry) {
        if (!isPlainObject(entry) || !isPlainObject(entry.agent) || !isPlainObject(entry.project)) {
          throw new Error("malformed fetchAgents entry");
        }
        requireOpaqueId(entry.agent.id, "agent id");
        return entry.agent;
      },
    });
    return entries;
  }

  /** Fetch every authoritative workspace using the exact cursor payload. */
  async fetchAllWorkspaces(options = {}) {
    return this.#fetchCursorPages({
      method: "fetchWorkspaces",
      limit: options.limit ?? DEFAULT_PAGE_LIMIT,
      maxPages: options.maxPages ?? DEFAULT_MAX_PAGES,
      baseOptions: options.filter ? { filter: options.filter } : {},
      entryValidator(entry) {
        if (!isPlainObject(entry)) throw new Error("malformed fetchWorkspaces entry");
        requireOpaqueId(entry.id, "workspace id");
        return entry;
      },
    });
  }

  /** Verify workspace existence by public idPrefix filter plus exact ID match. */
  async fetchWorkspace(workspaceId) {
    const expectedId = requireOpaqueId(workspaceId, "workspaceId");
    const entries = await this.fetchAllWorkspaces({ filter: { idPrefix: expectedId } });
    const exact = entries.filter((entry) => entry.id === expectedId);
    if (exact.length > 1) throw new Error("duplicate authoritative workspace");
    return exact[0] || null;
  }

  async close() {
    for (const stop of this.unsubscribers.splice(0)) {
      try {
        stop();
      } catch {
        // SDK unsubscribe is best-effort during shutdown.
      }
    }
    if (this.client) {
      try {
        await this.client.close();
      } catch {
        // Shutdown remains bounded by the service owner.
      }
    }
    this.client = null;
    this.connected = false;
    this.serverId = null;
  }

  async #fetchCursorPages({ method, limit, maxPages, baseOptions, entryValidator }) {
    requireInteger(limit, 1, 500, "page limit");
    requireInteger(maxPages, 1, 1000, "max pages");
    const values = [];
    const seenCursors = new Set();
    let cursor;
    for (let page = 0; page < maxPages; page += 1) {
      const pageRequest = cursor === undefined ? { limit } : { limit, cursor };
      const result = await this.client[method]({ ...baseOptions, page: pageRequest });
      const parsed = validatePagePayload(result, method);
      for (const entry of parsed.entries) values.push(entryValidator(entry));
      if (!parsed.pageInfo.hasMore) return values;
      const next = parsed.pageInfo.nextCursor;
      if (typeof next !== "string" || !next) throw new Error(`${method} missing next cursor`);
      if (seenCursors.has(next) || next === cursor) throw new Error(`${method} repeated cursor`);
      seenCursors.add(next);
      cursor = next;
    }
    throw new Error(`${method} incomplete pagination`);
  }

  #handleConnection(status) {
    this.connected = status?.status === "connected";
    if (this.connected) this.#refreshServerId();
    else this.serverId = null;
    this.logger.info("daemon_connection", {
      status: typeof status?.status === "string" ? status.status : "unknown",
      serverFp: this.serverId ? fingerprint(this.serverId) : undefined,
    });
    this.#emitSafe(this.connectionHandlers, status, "connection_callback_failed");
  }

  #refreshServerId() {
    try {
      const info = this.client?.getLastServerInfoMessage?.();
      this.serverId = normalizeOpaqueId(info?.serverId);
    } catch {
      this.serverId = null;
    }
  }

  #emitSafe(handlers, value, errorEvent) {
    for (const handler of handlers) {
      try {
        Promise.resolve(handler(value)).catch(() => {
          this.logger.error(errorEvent, { reason: "rejected" });
        });
      } catch {
        this.logger.error(errorEvent, { reason: "threw" });
      }
    }
  }
}

function validatePagePayload(value, method) {
  if (!isPlainObject(value) || !Array.isArray(value.entries) || !isPlainObject(value.pageInfo)) {
    throw new Error(`malformed ${method} response`);
  }
  const pageInfo = value.pageInfo;
  if (typeof pageInfo.hasMore !== "boolean") throw new Error(`malformed ${method} pageInfo`);
  if (pageInfo.nextCursor !== null && typeof pageInfo.nextCursor !== "string") {
    throw new Error(`malformed ${method} nextCursor`);
  }
  if (pageInfo.prevCursor !== null && typeof pageInfo.prevCursor !== "string") {
    throw new Error(`malformed ${method} prevCursor`);
  }
  return value;
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function requireOpaqueId(value, name) {
  const normalized = normalizeOpaqueId(value);
  if (!normalized || normalized !== value) throw new Error(name);
  return normalized;
}

function requireInteger(value, min, max, name) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(name);
}

export { validatePagePayload };
