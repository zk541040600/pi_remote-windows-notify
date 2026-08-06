import { join } from "node:path";
import { readFile } from "node:fs/promises";
import { atomicWriteFile, ensurePrivateDir } from "./atomic.mjs";
import { createLogger, fingerprint } from "./privacy.mjs";
import { validateHealthSnapshot } from "./delivery.mjs";

const LEASE_SCHEMA = 1;

/**
 * @typedef {object} HealthLease
 * @property {number} schemaVersion
 * @property {number} lastHealthyAt
 * @property {string} status
 * @property {string} [routeState]
 */

/**
 * Health lease owner: only refreshes when daemon connected+server_info AND
 * authenticated POST /paseo/health returns schema v1 ready + capabilities.
 */
export class HealthLeaseOwner {
  /**
   * @param {{
   *   stateDir: string,
   *   staleMs?: number,
   *   logger?: ReturnType<typeof createLogger>,
   *   now?: () => number,
   * }} options
   */
  constructor(options) {
    this.path = join(options.stateDir, "health.json");
    this.stateDir = options.stateDir;
    this.staleMs = options.staleMs ?? 15_000;
    this.logger = options.logger || createLogger();
    this.now = options.now || (() => Date.now());
    /** @type {HealthLease | null} */
    this.lease = null;
  }

  async load() {
    await ensurePrivateDir(this.stateDir);
    try {
      const raw = await readFile(this.path, "utf8");
      const parsed = JSON.parse(raw);
      if (parsed && parsed.schemaVersion === LEASE_SCHEMA && typeof parsed.lastHealthyAt === "number") {
        this.lease = {
          schemaVersion: LEASE_SCHEMA,
          lastHealthyAt: parsed.lastHealthyAt,
          status: typeof parsed.status === "string" ? parsed.status : "unknown",
          routeState: typeof parsed.routeState === "string" ? parsed.routeState : undefined,
        };
      }
    } catch {
      this.lease = null;
    }
    return this.lease;
  }

  /**
   * @param {{
   *   daemonConnected: boolean,
   *   serverId: string | null,
   *   windowsHealth: { ok: boolean, ready: boolean, reason?: string, snapshot?: any },
   * }} input
   */
  async refresh(input) {
    const now = this.now();
    if (!input.daemonConnected || !input.serverId) {
      this.logger.info("lease_skip", { reason: "daemon-not-ready" });
      return { refreshed: false, reason: "daemon-not-ready" };
    }
    if (!input.windowsHealth.ok || !input.windowsHealth.ready) {
      this.logger.info("lease_skip", {
        reason: input.windowsHealth.reason || "windows-not-ready",
      });
      return { refreshed: false, reason: input.windowsHealth.reason || "windows-not-ready" };
    }
    const snapshot = input.windowsHealth.snapshot;
    const valid = validateHealthSnapshot(snapshot);
    if (!valid.ok) {
      return { refreshed: false, reason: valid.reason };
    }

    /** @type {HealthLease} */
    const lease = {
      schemaVersion: LEASE_SCHEMA,
      lastHealthyAt: now,
      status: "healthy",
      routeState: typeof snapshot.routeState === "string" ? snapshot.routeState : undefined,
    };
    await atomicWriteFile(this.path, JSON.stringify(lease, null, 2), { mode: 0o600 });
    this.lease = lease;
    this.logger.info("lease_refresh", {
      serverFp: fingerprint(input.serverId),
      routeState: lease.routeState || "unknown",
    });
    return { refreshed: true, lease };
  }

  /**
   * Is the current lease healthy (age <= staleMs, no clock rollback)?
   * Fail-open for Pi: returns false on any doubt.
   */
  isHealthy() {
    return isLeaseHealthy(this.lease, { staleMs: this.staleMs, now: this.now() });
  }
}

/**
 * Pure lease health check used by Pi extension and sender.
 * Fail-open (return false => do not suppress Pi) on any error.
 * @param {any} lease
 * @param {{ staleMs?: number, now?: number }} [options]
 */
export function isLeaseHealthy(lease, options = {}) {
  const staleMs = options.staleMs ?? 15_000;
  const now = options.now ?? Date.now();
  if (!lease || typeof lease !== "object") return false;
  if (lease.schemaVersion !== LEASE_SCHEMA) return false;
  if (typeof lease.lastHealthyAt !== "number" || !Number.isFinite(lease.lastHealthyAt)) return false;
  if (lease.lastHealthyAt > now) {
    // Any future timestamp means clock rollback or an untrusted lease.
    return false;
  }
  if (now - lease.lastHealthyAt > staleMs) return false;
  if (lease.status !== "healthy") return false;
  return true;
}

/**
 * Read lease file for Pi extension. Never throws.
 * @param {string} path
 * @param {{ staleMs?: number, now?: number, readFileImpl?: typeof readFile }} [options]
 */
export async function readLeaseFile(path, options = {}) {
  const readImpl = options.readFileImpl || readFile;
  try {
    const raw = await readImpl(path, "utf8");
    const parsed = JSON.parse(raw);
    return {
      lease: parsed,
      healthy: isLeaseHealthy(parsed, { staleMs: options.staleMs, now: options.now }),
    };
  } catch {
    return { lease: null, healthy: false };
  }
}

export { LEASE_SCHEMA };
