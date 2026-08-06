import { randomUUID } from "node:crypto";
import { readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import {
  atomicWriteFile,
  ensurePrivateDir,
  fsyncDirectory,
  readMode,
} from "./atomic.mjs";
import {
  agentKey,
  createLogger,
  fingerprint,
  normalizeOpaqueId,
} from "./privacy.mjs";

const STATE_SCHEMA = 2;
const OUTBOX_SCHEMA = 2;
const WAL_SCHEMA = 1;
const MAX_PROCESSED_FINGERPRINTS = 4096;
const MAX_WATERMARKS = 2048;
const MAX_OUTBOX_ITEMS = 512;
const MAX_PENDING_AUTHORITY = 1024;
const MAX_PERMISSION_AGENTS = 2048;
const MAX_PERMISSION_IDS = 256;
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_WAL_BYTES = 4 * 1024 * 1024;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SHA256_RE = /^[0-9a-f]{64}$/u;
const SAFE_CODE_RE = /^[a-z0-9-]{1,64}$/u;

/**
 * @typedef {object} OutboxItem
 * @property {string} agentKey
 * @property {string} serverId
 * @property {string} agentId
 * @property {string} workspaceId
 * @property {"finished" | "permission"} kind
 * @property {string} notificationId
 * @property {string} eventTimestamp
 * @property {number} eventMs
 * @property {string[]} permissionRequestIds
 * @property {"pending" | "delivered" | "closing" | "terminal" | "invalid"} status
 * @property {number} attempts
 * @property {number} nextAttemptAt
 * @property {number} updatedAt
 * @property {number} [deadlineMs]
 * @property {number} [desktopShownAt]
 * @property {string} [lastResult]
 * @property {string} [errorCode]
 * @property {boolean} [removeAfterClose]
 * @property {string} [supersededNotificationId]
 */

/**
 * @typedef {object} PendingAuthorityItem
 * @property {string} eventFp
 * @property {string} serverId
 * @property {string} agentId
 * @property {"finished" | "permission"} reason
 * @property {string} timestamp
 * @property {number} eventMs
 * @property {number} attempts
 * @property {number} nextAttemptAt
 * @property {number} createdAt
 * @property {number} updatedAt
 * @property {string} [lastError]
 */

/**
 * Durable state + outbox with one write-ahead transaction record. A valid WAL is
 * replayed on startup, so a crash between outbox.json and state.json renames
 * cannot expose a mixed generation.
 */
export class DurableStore {
  /**
   * @param {string} stateDir
   * @param {{ logger?: ReturnType<typeof createLogger>, faultInjector?: (point: string) => void | Promise<void>, now?: () => number }} [options]
   */
  constructor(stateDir, options = {}) {
    this.stateDir = stateDir;
    this.statePath = join(stateDir, "state.json");
    this.outboxPath = join(stateDir, "outbox.json");
    this.walPath = join(stateDir, "transaction.json");
    this.quarantineDir = join(stateDir, "quarantine");
    this.logger = options.logger || createLogger();
    this.faultInjector = options.faultInjector;
    this.now = options.now || (() => Date.now());
    this.state = emptyState();
    this.outbox = emptyOutbox();
    this.corrupt = false;
    this.corruptReason = "";
    this.writeChain = Promise.resolve();
    this.loaded = false;
  }

  async load() {
    await ensurePrivateDir(this.stateDir);
    await ensurePrivateDir(this.quarantineDir);

    const [stateFile, outboxFile, walFile] = await Promise.all([
      this.#readArtifact(this.statePath, "state", MAX_FILE_BYTES, validateState),
      this.#readArtifact(this.outboxPath, "outbox", MAX_FILE_BYTES, validateOutbox),
      this.#readArtifact(this.walPath, "wal", MAX_WAL_BYTES, validateWal),
    ]);
    const invalid = [stateFile, outboxFile, walFile].find((entry) => entry.invalid);
    if (invalid) {
      await this.#blockAndQuarantine(invalid.path, invalid.kind, invalid.reason);
      this.loaded = true;
      return { ok: false, reason: this.corruptReason };
    }

    if (walFile.value) {
      const recovered = await this.#recoverWal(walFile.value, stateFile.value, outboxFile.value);
      if (!recovered.ok) {
        await this.#blockAndQuarantine(this.walPath, "wal", recovered.reason);
        this.loaded = true;
        return { ok: false, reason: this.corruptReason };
      }
      this.state = structuredClone(walFile.value.state);
      this.outbox = structuredClone(walFile.value.outbox);
      this.loaded = true;
      return { ok: true, recovered: true };
    }

    if (Boolean(stateFile.value) !== Boolean(outboxFile.value)) {
      this.#block("generation:missing-pair");
      this.loaded = true;
      return { ok: false, reason: this.corruptReason };
    }
    if (stateFile.value && outboxFile.value) {
      if (stateFile.value.generation !== outboxFile.value.generation) {
        this.#block("generation:mismatch");
        this.loaded = true;
        return { ok: false, reason: this.corruptReason };
      }
      this.state = structuredClone(stateFile.value);
      this.outbox = structuredClone(outboxFile.value);
    }
    this.loaded = true;
    return { ok: true, recovered: false };
  }

  isLiveDeliveryBlocked() {
    return this.corrupt || !this.loaded;
  }

  /** Wait until every transaction already queued on the single writer has settled. */
  whenIdle() {
    return this.writeChain;
  }

  /**
   * Serialize mutation and persistence. Persistence failure restores the prior
   * in-memory generation and blocks this process from further live work.
   * @template T
   * @param {() => T | Promise<T>} mutator
   */
  async transaction(mutator) {
    const run = this.writeChain.then(async () => {
      if (this.isLiveDeliveryBlocked()) {
        throw new Error(`store blocked: ${this.corruptReason || "not-loaded"}`);
      }
      const beforeState = structuredClone(this.state);
      const beforeOutbox = structuredClone(this.outbox);
      try {
        const result = await mutator();
        validateStateForMutation(this.state);
        validateOutboxForMutation(this.outbox);
        await this.#persistBoth();
        return result;
      } catch (error) {
        this.state = beforeState;
        this.outbox = beforeOutbox;
        this.#block(`persist:${error instanceof Error ? error.name : "error"}`);
        throw error;
      }
    });
    this.writeChain = run.then(() => undefined, () => undefined);
    return run;
  }

  hasProcessedEvent(eventFp) {
    return this.state.processedEventFingerprints.includes(eventFp);
  }

  markProcessedEvent(eventFp) {
    if (!SHA256_RE.test(eventFp)) throw new Error("invalid event fingerprint");
    if (this.state.processedEventFingerprints.includes(eventFp)) return;
    this.state.processedEventFingerprints.push(eventFp);
    while (this.state.processedEventFingerprints.length > MAX_PROCESSED_FINGERPRINTS) {
      this.state.processedEventFingerprints.shift();
    }
    this.state.updatedAt = this.now();
  }

  recordPendingAttention(event) {
    if (this.hasProcessedEvent(event.eventFp)) return { recorded: false, reason: "processed" };
    if (this.state.pendingAuthority[event.eventFp]) return { recorded: false, reason: "pending" };
    if (Object.keys(this.state.pendingAuthority).length >= MAX_PENDING_AUTHORITY) {
      throw new Error("pending authority limit reached");
    }
    const now = this.now();
    this.state.pendingAuthority[event.eventFp] = {
      eventFp: event.eventFp,
      serverId: requireOpaqueId(event.serverId, "serverId"),
      agentId: requireOpaqueId(event.agentId, "agentId"),
      reason: requireKind(event.reason),
      timestamp: requireTimestamp(event.timestamp, "timestamp"),
      eventMs: requireFiniteTime(event.eventMs, "eventMs"),
      attempts: 0,
      nextAttemptAt: now,
      createdAt: now,
      updatedAt: now,
    };
    this.state.updatedAt = now;
    return { recorded: true, item: this.state.pendingAuthority[event.eventFp] };
  }

  listPendingAuthority() {
    return Object.values(this.state.pendingAuthority);
  }

  getPendingAuthority(eventFp) {
    return this.state.pendingAuthority[eventFp];
  }

  schedulePendingAuthority(eventFp, options) {
    const item = this.state.pendingAuthority[eventFp];
    if (!item) return false;
    item.attempts = requireInteger(options.attempts, 0, 1_000_000, "attempts");
    item.nextAttemptAt = requireFiniteTime(options.nextAttemptAt, "nextAttemptAt");
    item.updatedAt = this.now();
    item.lastError = requireSafeCode(options.lastError || "authority-retry", "lastError");
    this.state.updatedAt = item.updatedAt;
    return true;
  }

  completePendingAttention(eventFp) {
    if (!this.state.pendingAuthority[eventFp]) return false;
    delete this.state.pendingAuthority[eventFp];
    this.markProcessedEvent(eventFp);
    return true;
  }

  getWatermark(serverId, agentId) {
    return this.state.completionWatermarks[agentKey({ serverId, agentId })] || null;
  }

  setWatermark(serverId, agentId, isoTimestamp) {
    const key = agentKey({ serverId, agentId });
    const timestamp = requireTimestamp(isoTimestamp, "watermark");
    const existing = this.state.completionWatermarks[key];
    if (!existing || Date.parse(timestamp) > Date.parse(existing)) {
      this.state.completionWatermarks[key] = timestamp;
      const keys = Object.keys(this.state.completionWatermarks);
      if (keys.length > MAX_WATERMARKS) delete this.state.completionWatermarks[keys[0]];
    }
    this.state.updatedAt = this.now();
  }

  hasTimestampWarning(serverId, agentId) {
    return this.state.timestampWarningAgents.includes(agentKey({ serverId, agentId }));
  }

  markTimestampWarning(serverId, agentId) {
    const key = agentKey({ serverId, agentId });
    if (!this.state.timestampWarningAgents.includes(key)) {
      this.state.timestampWarningAgents.push(key);
      while (this.state.timestampWarningAgents.length > MAX_WATERMARKS) {
        this.state.timestampWarningAgents.shift();
      }
    }
    this.state.updatedAt = this.now();
  }

  markInitialized(serverId) {
    this.state.initialized = true;
    this.state.serverId = requireOpaqueId(serverId, "serverId");
    this.state.updatedAt = this.now();
  }

  getItem(key) {
    return this.outbox.items[key];
  }

  listItems() {
    return Object.values(this.outbox.items);
  }

  /** Permission request lifecycle is correlation only; this never creates outbox. */
  addPermissionCorrelation(serverId, agentId, requestId) {
    const key = agentKey({ serverId, agentId });
    const id = requireOpaqueId(requestId, "requestId");
    const current = this.state.permissionCorrelations[key] || [];
    this.state.permissionCorrelations[key] = uniqueIds([...current, id]);
    this.state.resolvedPermissionIds[key] = (this.state.resolvedPermissionIds[key] || []).filter(
      (value) => value !== id,
    );
    this.state.updatedAt = this.now();
    this.#boundPermissionMaps();
    return this.state.permissionCorrelations[key];
  }

  markPermissionResolved(serverId, agentId, requestId) {
    const key = agentKey({ serverId, agentId });
    const id = requireOpaqueId(requestId, "requestId");
    this.state.permissionCorrelations[key] = (this.state.permissionCorrelations[key] || []).filter(
      (value) => value !== id,
    );
    if (this.state.permissionCorrelations[key].length === 0) delete this.state.permissionCorrelations[key];
    this.state.resolvedPermissionIds[key] = uniqueIds([
      ...(this.state.resolvedPermissionIds[key] || []),
      id,
    ]);
    this.state.updatedAt = this.now();
    this.#boundPermissionMaps();
  }

  permissionIdsForTriggeredAttention(serverId, agentId, authoritativeIds) {
    const key = agentKey({ serverId, agentId });
    const resolved = new Set(this.state.resolvedPermissionIds[key] || []);
    return uniqueIds([
      ...authoritativeIds,
      ...(this.state.permissionCorrelations[key] || []),
    ]).filter((id) => !resolved.has(id));
  }

  authoritativePermissionIds(serverId, agentId, authoritativeIds) {
    const key = agentKey({ serverId, agentId });
    const resolved = new Set(this.state.resolvedPermissionIds[key] || []);
    return uniqueIds(authoritativeIds).filter((id) => !resolved.has(id));
  }

  /** Replace lifecycle correlation with the complete authoritative pending set. */
  syncPermissionAuthority(serverId, agentId, authoritativeIds) {
    const key = agentKey({ serverId, agentId });
    const ids = uniqueIds(authoritativeIds);
    const item = this.outbox.items[key];
    const previous = new Set([
      ...(this.state.permissionCorrelations[key] || []),
      ...(item?.kind === "permission" ? item.permissionRequestIds : []),
    ]);
    const stale = [...previous].filter((id) => !ids.includes(id));
    const resolved = [
      ...(this.state.resolvedPermissionIds[key] || []),
      ...stale,
    ].filter((id) => !ids.includes(id));
    const boundedResolved = [...new Set(resolved)].slice(-MAX_PERMISSION_IDS);

    if (ids.length > 0) this.state.permissionCorrelations[key] = ids;
    else delete this.state.permissionCorrelations[key];
    if (boundedResolved.length > 0) this.state.resolvedPermissionIds[key] = boundedResolved;
    else delete this.state.resolvedPermissionIds[key];
    this.state.updatedAt = this.now();
    this.#boundPermissionMaps();
    return ids;
  }

  /** Upsert one display item per agent. Permission dominates finished. */
  upsertItem(input) {
    const serverId = requireOpaqueId(input.serverId, "serverId");
    const agentId = requireOpaqueId(input.agentId, "agentId");
    const workspaceId = requireOpaqueId(input.workspaceId, "workspaceId");
    const key = agentKey({ serverId, agentId });
    const existing = this.outbox.items[key];
    const now = this.now();

    if (
      existing &&
      existing.kind === "permission" &&
      existing.permissionRequestIds.length > 0 &&
      input.kind === "finished" &&
      existing.status !== "terminal" &&
      existing.status !== "invalid"
    ) {
      return existing;
    }

    const permissionIds = uniqueIds(input.permissionRequestIds || existing?.permissionRequestIds || []);
    const kind = permissionIds.length > 0 ? "permission" : requireKind(input.kind);
    const eventTimestamp = requireTimestamp(
      input.eventTimestamp || existing?.eventTimestamp || new Date(now).toISOString(),
      "eventTimestamp",
    );
    const eventMs = requireFiniteTime(input.eventMs ?? existing?.eventMs ?? now, "eventMs");
    const addedPermissionIds = kind === "permission" && existing?.kind === "permission"
      ? permissionIds.some((id) => !existing.permissionRequestIds.includes(id))
      : false;
    const newEpisode =
      Boolean(input.forceNewEpisode) ||
      !existing ||
      existing.status === "terminal" ||
      existing.status === "invalid" ||
      (existing.status === "closing" && kind === "permission") ||
      existing.kind !== kind ||
      (kind === "finished" && existing.eventTimestamp !== eventTimestamp) ||
      addedPermissionIds;

    const item = {
      agentKey: key,
      serverId,
      agentId,
      workspaceId,
      kind,
      notificationId: newEpisode ? randomUUID() : existing.notificationId,
      eventTimestamp,
      eventMs,
      permissionRequestIds: permissionIds,
      status: newEpisode ? (input.status || "pending") : (input.status || existing.status),
      attempts: newEpisode ? 0 : existing.attempts,
      nextAttemptAt: newEpisode ? (input.nextAttemptAt ?? now) : existing.nextAttemptAt,
      updatedAt: now,
      deadlineMs:
        kind === "finished"
          ? (input.deadlineMs ?? eventMs + (input.finishedTtlMs || 30 * 60 * 1000))
          : undefined,
      desktopShownAt: newEpisode ? undefined : existing.desktopShownAt,
      lastResult: newEpisode ? undefined : existing.lastResult,
      errorCode: newEpisode ? undefined : existing.errorCode,
      removeAfterClose: newEpisode ? undefined : existing.removeAfterClose,
      // Keep close identity for any previously displayed UUID across episodes.
      supersededNotificationId: newEpisode
        ? (existing?.desktopShownAt !== undefined
          ? existing.notificationId
          : existing?.supersededNotificationId)
        : existing?.supersededNotificationId,
    };

    if (!existing && Object.keys(this.outbox.items).length >= MAX_OUTBOX_ITEMS) {
      const removable = this.listItems()
        .filter((entry) => entry.status === "terminal" || entry.status === "invalid")
        .sort((a, b) => a.updatedAt - b.updatedAt)[0];
      if (!removable) throw new Error("outbox item limit reached");
      delete this.outbox.items[removable.agentKey];
    }
    this.outbox.items[key] = stripUndefined(item);
    this.outbox.updatedAt = now;
    return this.outbox.items[key];
  }

  resolvePermissionId(serverId, agentId, requestId) {
    this.markPermissionResolved(serverId, agentId, requestId);
    const key = agentKey({ serverId, agentId });
    const item = this.outbox.items[key];
    if (!item || item.kind !== "permission") {
      return { found: false, allResolved: false, item: null };
    }
    const before = item.permissionRequestIds.length;
    item.permissionRequestIds = item.permissionRequestIds.filter((id) => id !== requestId);
    item.updatedAt = this.now();
    this.outbox.updatedAt = item.updatedAt;
    const found = before !== item.permissionRequestIds.length;
    const allResolved = found && item.permissionRequestIds.length === 0;
    if (allResolved) this.#closeOrRemovePermission(item);
    return { found, allResolved, item: this.outbox.items[key] || null };
  }

  syncPermissionSet(serverId, agentId, workspaceId, requestIds, meta = {}) {
    const key = agentKey({ serverId, agentId });
    const ids = uniqueIds(requestIds);
    const existing = this.outbox.items[key];
    if (ids.length === 0) {
      if (existing?.kind === "permission") this.#closeOrRemovePermission(existing);
      return this.outbox.items[key] || null;
    }

    if (existing?.kind === "permission") {
      if (setsEqual(existing.permissionRequestIds, ids)) {
        // Ordinary reconnect / same authoritative set: preserve UUID and delivered state.
        existing.workspaceId = requireOpaqueId(workspaceId, "workspaceId");
        existing.updatedAt = this.now();
        this.outbox.updatedAt = existing.updatedAt;
        return existing;
      }
      const added = ids.some((id) => !existing.permissionRequestIds.includes(id));
      if (!added) {
        // Subset-only change (partial resolution): keep same card/UUID.
        existing.permissionRequestIds = ids;
        existing.workspaceId = requireOpaqueId(workspaceId, "workspaceId");
        existing.updatedAt = this.now();
        this.outbox.updatedAt = existing.updatedAt;
        return existing;
      }
    }

    // Any newly added request ID (or disjoint set) starts a fresh permission episode.
    const item = this.upsertItem({
      serverId,
      agentId,
      workspaceId,
      kind: "permission",
      permissionRequestIds: ids,
      eventTimestamp: meta.eventTimestamp || existing?.eventTimestamp || new Date(this.now()).toISOString(),
      eventMs: meta.eventMs ?? existing?.eventMs ?? this.now(),
      status: "pending",
      forceNewEpisode: true,
    });
    item.permissionRequestIds = ids;
    return item;
  }

  removeItem(key) {
    if (!this.outbox.items[key]) return false;
    delete this.outbox.items[key];
    this.outbox.updatedAt = this.now();
    return true;
  }

  markAgentMissing(serverId, agentId) {
    const key = agentKey({ serverId, agentId });
    const item = this.outbox.items[key];
    if (item?.kind === "permission" && item.desktopShownAt !== undefined) {
      item.permissionRequestIds = [];
      item.status = "closing";
      item.removeAfterClose = true;
      item.nextAttemptAt = this.now();
      item.updatedAt = this.now();
      this.outbox.updatedAt = item.updatedAt;
    } else {
      this.removeItem(key);
    }
    delete this.state.completionWatermarks[key];
    delete this.state.permissionCorrelations[key];
    delete this.state.resolvedPermissionIds[key];
    for (const [eventFp, pending] of Object.entries(this.state.pendingAuthority)) {
      if (pending.serverId === serverId && pending.agentId === agentId) {
        delete this.state.pendingAuthority[eventFp];
        this.markProcessedEvent(eventFp);
      }
    }
    this.state.updatedAt = this.now();
    return Boolean(item);
  }

  removeAgent(serverId, agentId) {
    return this.markAgentMissing(serverId, agentId);
  }

  #closeOrRemovePermission(item) {
    if (item.desktopShownAt === undefined) {
      this.removeItem(item.agentKey);
      return;
    }
    item.permissionRequestIds = [];
    item.status = "closing";
    item.removeAfterClose = true;
    item.nextAttemptAt = this.now();
    item.updatedAt = this.now();
    this.outbox.updatedAt = item.updatedAt;
  }

  #boundPermissionMaps() {
    for (const map of [this.state.permissionCorrelations, this.state.resolvedPermissionIds]) {
      const keys = Object.keys(map);
      while (keys.length > MAX_PERMISSION_AGENTS) delete map[keys.shift()];
    }
  }

  async #persistBoth() {
    const generation = this.state.generation + 1;
    const nextState = { ...structuredClone(this.state), generation, updatedAt: this.now() };
    const nextOutbox = { ...structuredClone(this.outbox), generation, updatedAt: this.now() };
    validateState(nextState);
    validateOutbox(nextOutbox);
    const wal = { schemaVersion: WAL_SCHEMA, generation, state: nextState, outbox: nextOutbox };
    const stateJson = stringifyBounded(nextState, MAX_FILE_BYTES, "state");
    const outboxJson = stringifyBounded(nextOutbox, MAX_FILE_BYTES, "outbox");
    const walJson = stringifyBounded(wal, MAX_WAL_BYTES, "wal");

    await atomicWriteFile(this.walPath, walJson, { mode: 0o600 });
    await this.#inject("after-wal");
    await atomicWriteFile(this.outboxPath, outboxJson, { mode: 0o600 });
    await this.#inject("after-outbox");
    await atomicWriteFile(this.statePath, stateJson, { mode: 0o600 });
    await this.#inject("after-state");
    await fsyncDirectory(this.stateDir);
    await rm(this.walPath, { force: true });
    await fsyncDirectory(this.stateDir);
    this.state = nextState;
    this.outbox = nextOutbox;
  }

  async #recoverWal(wal, state, outbox) {
    const existingGenerations = [state?.generation ?? 0, outbox?.generation ?? 0];
    if (existingGenerations.some((generation) => generation > wal.generation)) {
      return { ok: false, reason: "generation-ahead" };
    }
    if (existingGenerations.some((generation) => generation < wal.generation - 1)) {
      return { ok: false, reason: "generation-gap" };
    }
    await atomicWriteFile(this.outboxPath, stringifyBounded(wal.outbox, MAX_FILE_BYTES, "outbox"), { mode: 0o600 });
    await atomicWriteFile(this.statePath, stringifyBounded(wal.state, MAX_FILE_BYTES, "state"), { mode: 0o600 });
    await fsyncDirectory(this.stateDir);
    await rm(this.walPath, { force: true });
    await fsyncDirectory(this.stateDir);
    return { ok: true };
  }

  async #readArtifact(path, kind, maxBytes, validator) {
    let raw;
    try {
      raw = await readFile(path, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") return { path, kind, value: null, invalid: false };
      return { path, kind, value: null, invalid: true, reason: "unreadable" };
    }
    if (Buffer.byteLength(raw, "utf8") > maxBytes) {
      return { path, kind, value: null, invalid: true, reason: "too-large" };
    }
    if (process.platform !== "win32" && await readMode(path) !== 0o600) {
      return { path, kind, value: null, invalid: true, reason: "unsafe-mode" };
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
      validator(parsed);
    } catch (error) {
      return {
        path,
        kind,
        value: null,
        invalid: true,
        reason: error instanceof SyntaxError ? "invalid-json" : "invalid-schema",
      };
    }
    return { path, kind, value: parsed, invalid: false };
  }

  async #blockAndQuarantine(path, kind, reason) {
    this.#block(`${kind}:${reason}`);
    const dest = join(this.quarantineDir, `${kind}-${this.now()}-${reason}.json`);
    try {
      await rename(path, dest);
    } catch {
      // Keep the original artifact when quarantine rename itself is unavailable.
    }
    this.logger.error("store_quarantine", { kind, reason, destFp: fingerprint(dest) });
  }

  #block(reason) {
    this.corrupt = true;
    this.corruptReason = reason;
    this.logger.error("store_blocked", { reason, stateFp: fingerprint(this.statePath) });
  }

  async #inject(point) {
    if (this.faultInjector) await this.faultInjector(point);
  }
}

function emptyState() {
  return {
    schemaVersion: STATE_SCHEMA,
    generation: 0,
    initialized: false,
    serverId: null,
    completionWatermarks: {},
    processedEventFingerprints: [],
    timestampWarningAgents: [],
    pendingAuthority: {},
    permissionCorrelations: {},
    resolvedPermissionIds: {},
    updatedAt: Date.now(),
  };
}

function emptyOutbox() {
  return { schemaVersion: OUTBOX_SCHEMA, generation: 0, items: {}, updatedAt: Date.now() };
}

function validateStateForMutation(value) {
  validateState({ ...value, generation: value.generation });
}

function validateOutboxForMutation(value) {
  validateOutbox({ ...value, generation: value.generation });
}

function validateState(value) {
  requirePlainObject(value, "state");
  requireExactKeys(value, [
    "schemaVersion", "generation", "initialized", "serverId", "completionWatermarks",
    "processedEventFingerprints", "timestampWarningAgents", "pendingAuthority",
    "permissionCorrelations", "resolvedPermissionIds", "updatedAt",
  ], "state");
  if (value.schemaVersion !== STATE_SCHEMA) throw new Error("state schema");
  requireInteger(value.generation, 0, Number.MAX_SAFE_INTEGER, "generation");
  if (typeof value.initialized !== "boolean") throw new Error("initialized");
  if (value.serverId !== null) requireOpaqueId(value.serverId, "serverId");
  requireFiniteTime(value.updatedAt, "updatedAt");
  validateHashTimestampMap(value.completionWatermarks, MAX_WATERMARKS, "watermarks");
  validateHashArray(value.processedEventFingerprints, MAX_PROCESSED_FINGERPRINTS, "processed");
  validateHashArray(value.timestampWarningAgents, MAX_WATERMARKS, "warnings");
  requirePlainObject(value.pendingAuthority, "pendingAuthority");
  if (Object.keys(value.pendingAuthority).length > MAX_PENDING_AUTHORITY) throw new Error("pending count");
  for (const [key, item] of Object.entries(value.pendingAuthority)) validatePendingAuthority(key, item);
  validatePermissionMap(value.permissionCorrelations, "permissionCorrelations");
  validatePermissionMap(value.resolvedPermissionIds, "resolvedPermissionIds");
  return true;
}

function validateOutbox(value) {
  requirePlainObject(value, "outbox");
  requireExactKeys(value, ["schemaVersion", "generation", "items", "updatedAt"], "outbox");
  if (value.schemaVersion !== OUTBOX_SCHEMA) throw new Error("outbox schema");
  requireInteger(value.generation, 0, Number.MAX_SAFE_INTEGER, "generation");
  requireFiniteTime(value.updatedAt, "updatedAt");
  requirePlainObject(value.items, "items");
  if (Object.keys(value.items).length > MAX_OUTBOX_ITEMS) throw new Error("outbox count");
  for (const [key, item] of Object.entries(value.items)) validateOutboxItem(key, item);
  return true;
}

function validateWal(value) {
  requirePlainObject(value, "wal");
  requireExactKeys(value, ["schemaVersion", "generation", "state", "outbox"], "wal");
  if (value.schemaVersion !== WAL_SCHEMA) throw new Error("wal schema");
  requireInteger(value.generation, 1, Number.MAX_SAFE_INTEGER, "generation");
  validateState(value.state);
  validateOutbox(value.outbox);
  if (value.state.generation !== value.generation || value.outbox.generation !== value.generation) {
    throw new Error("wal generation");
  }
  return true;
}

function validatePendingAuthority(key, item) {
  if (!SHA256_RE.test(key)) throw new Error("pending key");
  requirePlainObject(item, "pending item");
  requireExactKeys(item, [
    "eventFp", "serverId", "agentId", "reason", "timestamp", "eventMs", "attempts",
    "nextAttemptAt", "createdAt", "updatedAt", "lastError",
  ], "pending item", true);
  if (item.eventFp !== key) throw new Error("pending identity");
  requireOpaqueId(item.serverId, "serverId");
  requireOpaqueId(item.agentId, "agentId");
  requireKind(item.reason);
  requireTimestamp(item.timestamp, "timestamp");
  requireFiniteTime(item.eventMs, "eventMs");
  requireInteger(item.attempts, 0, 1_000_000, "attempts");
  requireFiniteTime(item.nextAttemptAt, "nextAttemptAt");
  requireFiniteTime(item.createdAt, "createdAt");
  requireFiniteTime(item.updatedAt, "updatedAt");
  if (item.lastError !== undefined) requireSafeCode(item.lastError, "lastError");
}

function validateOutboxItem(key, item) {
  if (!SHA256_RE.test(key)) throw new Error("item key");
  requirePlainObject(item, "item");
  requireExactKeys(item, [
    "agentKey", "serverId", "agentId", "workspaceId", "kind", "notificationId",
    "eventTimestamp", "eventMs", "permissionRequestIds", "status", "attempts",
    "nextAttemptAt", "updatedAt", "deadlineMs", "desktopShownAt", "lastResult",
    "errorCode", "removeAfterClose", "supersededNotificationId",
  ], "item", true);
  const serverId = requireOpaqueId(item.serverId, "serverId");
  const agentId = requireOpaqueId(item.agentId, "agentId");
  requireOpaqueId(item.workspaceId, "workspaceId");
  if (item.agentKey !== key || key !== agentKey({ serverId, agentId })) throw new Error("item identity");
  requireKind(item.kind);
  if (!UUID_RE.test(item.notificationId)) throw new Error("notificationId");
  requireTimestamp(item.eventTimestamp, "eventTimestamp");
  requireFiniteTime(item.eventMs, "eventMs");
  validatePermissionIds(item.permissionRequestIds);
  if (item.kind === "permission" && item.status !== "closing" && item.permissionRequestIds.length === 0) {
    throw new Error("empty active permission");
  }
  if (item.kind === "finished" && item.permissionRequestIds.length !== 0) throw new Error("finished ids");
  if (!["pending", "delivered", "closing", "terminal", "invalid"].includes(item.status)) throw new Error("status");
  requireInteger(item.attempts, 0, 1_000_000, "attempts");
  requireFiniteTime(item.nextAttemptAt, "nextAttemptAt");
  requireFiniteTime(item.updatedAt, "updatedAt");
  for (const field of ["deadlineMs", "desktopShownAt"]) {
    if (item[field] !== undefined) requireFiniteTime(item[field], field);
  }
  for (const field of ["lastResult", "errorCode"]) {
    if (item[field] !== undefined) requireSafeCode(item[field], field);
  }
  if (item.removeAfterClose !== undefined && typeof item.removeAfterClose !== "boolean") throw new Error("removeAfterClose");
  if (item.supersededNotificationId !== undefined && !UUID_RE.test(item.supersededNotificationId)) {
    throw new Error("supersededNotificationId");
  }
}

function validatePermissionMap(value, name) {
  requirePlainObject(value, name);
  if (Object.keys(value).length > MAX_PERMISSION_AGENTS) throw new Error(`${name} count`);
  for (const [key, ids] of Object.entries(value)) {
    if (!SHA256_RE.test(key)) throw new Error(`${name} key`);
    validatePermissionIds(ids);
  }
}

function validatePermissionIds(ids) {
  if (!Array.isArray(ids) || ids.length > MAX_PERMISSION_IDS) throw new Error("permission IDs");
  if (new Set(ids).size !== ids.length) throw new Error("duplicate permission IDs");
  for (const id of ids) requireOpaqueId(id, "permission ID");
}

function validateHashTimestampMap(value, max, name) {
  requirePlainObject(value, name);
  if (Object.keys(value).length > max) throw new Error(`${name} count`);
  for (const [key, timestamp] of Object.entries(value)) {
    if (!SHA256_RE.test(key)) throw new Error(`${name} key`);
    requireTimestamp(timestamp, name);
  }
}

function validateHashArray(value, max, name) {
  if (!Array.isArray(value) || value.length > max || new Set(value).size !== value.length) throw new Error(name);
  for (const key of value) if (!SHA256_RE.test(key)) throw new Error(`${name} key`);
}

function requirePlainObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(name);
}

function requireExactKeys(value, allowed, name, optional = false) {
  const allowedSet = new Set(allowed);
  if (Object.keys(value).some((key) => !allowedSet.has(key))) throw new Error(`${name} fields`);
  if (!optional) {
    for (const key of allowed) if (!Object.prototype.hasOwnProperty.call(value, key)) throw new Error(`${name} missing ${key}`);
  }
}

function requireOpaqueId(value, name) {
  const normalized = normalizeOpaqueId(value);
  if (!normalized || normalized !== value) throw new Error(name);
  return normalized;
}

function requireKind(value) {
  if (value !== "finished" && value !== "permission") throw new Error("kind");
  return value;
}

function requireTimestamp(value, name) {
  if (typeof value !== "string" || !value.trim() || !Number.isFinite(Date.parse(value))) throw new Error(name);
  return value;
}

function requireFiniteTime(value, name) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new Error(name);
  return value;
}

function requireInteger(value, min, max, name) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(name);
  return value;
}

function requireSafeCode(value, name) {
  if (typeof value !== "string" || !SAFE_CODE_RE.test(value)) throw new Error(name);
  return value;
}

function uniqueIds(ids) {
  const result = [];
  for (const value of ids) {
    const id = requireOpaqueId(value, "permission ID");
    if (!result.includes(id)) result.push(id);
  }
  if (result.length > MAX_PERMISSION_IDS) throw new Error("permission ID limit");
  return result;
}

function setsEqual(left, right) {
  return left.length === right.length && left.every((value) => right.includes(value));
}

function stripUndefined(value) {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function stringifyBounded(value, maxBytes, name) {
  const json = JSON.stringify(value, null, 2);
  if (Buffer.byteLength(json, "utf8") > maxBytes) throw new Error(`${name} file exceeds size bound`);
  return json;
}

export {
  STATE_SCHEMA,
  OUTBOX_SCHEMA,
  WAL_SCHEMA,
  MAX_OUTBOX_ITEMS,
  MAX_PROCESSED_FINGERPRINTS,
  emptyState,
  emptyOutbox,
  readMode,
  validateState,
  validateOutbox,
  validateWal,
};
