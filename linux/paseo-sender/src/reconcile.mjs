import { agentDisplayName, extractPermissionRequestIds, validateRoute } from "./normalize.mjs";
import { agentKey, createLogger, fingerprint, parseAttentionTimestamp } from "./privacy.mjs";

/** First-run baseline and reconnect reconciliation against complete snapshots. */
export class Reconciler {
  /**
   * @param {{ store: import("./store.mjs").DurableStore, logger?: ReturnType<typeof createLogger>, finishedTtlMs?: number, now?: () => number }} options
   */
  constructor(options) {
    this.store = options.store;
    this.logger = options.logger || createLogger();
    this.finishedTtlMs = options.finishedTtlMs ?? 30 * 60 * 1000;
    this.now = options.now || (() => Date.now());
  }

  /**
   * Reconcile only after both agent and workspace pagination completed.
   * Returns explicit unresolved counts so the service can keep authorityReady=false
   * and schedule a bounded retry when actionable work could not be queued.
   *
   * @returns {Promise<{
   *   watermarks: number,
   *   permissions: number,
   *   finishedEnqueued: number,
   *   warnings: number,
   *   unresolved: number,
   *   unresolvedPermissions: number,
   *   unresolvedFinished: number,
   *   displayNames: Map<string, string>,
   *   seenKeys: Set<string>,
   * }>}
   */
  async reconcile(input) {
    const { serverId, agents, isFirstRun } = input;
    const workspaceIds = input.workspaceIds instanceof Set
      ? input.workspaceIds
      : new Set(input.workspaces?.map((workspace) => workspace.id) || []);
    const pruneMissing = input.pruneMissing !== false;
    const seenKeys = new Set();
    /** @type {Map<string, string>} */
    const displayNames = new Map();
    let watermarks = 0;
    let permissions = 0;
    let finishedEnqueued = 0;
    let warnings = 0;
    let unresolvedPermissions = 0;
    let unresolvedFinished = 0;

    await this.store.transaction(() => {
      for (const agent of agents) {
        const agentId = agent.id;
        const key = agentKey({ serverId, agentId });
        seenKeys.add(key);
        // Snapshot title is display-only and never persisted; service holds it ephemerally.
        displayNames.set(key, agentDisplayName(agent, "Agent"));
        const workspaceId = typeof agent.workspaceId === "string" ? agent.workspaceId : "";
        const route = workspaceIds.has(workspaceId)
          ? validateRoute({ serverId, workspaceId, agentId })
          : { ok: false, reason: "workspace-authority" };
        const authoritativeIds = extractPermissionRequestIds(agent.pendingPermissions);
        const permissionIds = this.store.syncPermissionAuthority(serverId, agentId, authoritativeIds);

        if (permissionIds.length > 0) {
          if (route.ok) {
            this.store.syncPermissionSet(serverId, agentId, route.workspaceId, permissionIds, {
              eventTimestamp: new Date(this.now()).toISOString(),
              eventMs: this.now(),
            });
            permissions += 1;
          } else {
            // Actionable permission must not be silently lost when workspace authority is missing.
            this.logger.warn("permission_route_unresolved", {
              agentFp: fingerprint(agentId),
              reason: route.reason,
            });
            warnings += 1;
            unresolvedPermissions += 1;
          }
        } else if (route.ok) {
          this.store.syncPermissionSet(serverId, agentId, route.workspaceId, []);
        }

        if (agent.attentionReason !== "finished") continue;
        const timestamp = parseAttentionTimestamp(agent.attentionTimestamp, { now: this.now() });
        if (!timestamp.ok) {
          // Timestamp-missing finished is intentionally non-actionable and does not count as unresolved.
          if (!this.store.hasTimestampWarning(serverId, agentId)) {
            this.store.markTimestampWarning(serverId, agentId);
            this.logger.warn("attention_timestamp_unusable", {
              agentFp: fingerprint(agentId),
              reason: timestamp.reason,
            });
            warnings += 1;
          }
          continue;
        }

        const watermark = this.store.getWatermark(serverId, agentId);
        if (isFirstRun || !watermark) {
          // Without a persisted per-agent watermark there is no proof this completion is new.
          // Establish a baseline only after the complete workspace route is authoritative.
          if (!route.ok) {
            this.logger.warn("finished_route_unresolved", {
              agentFp: fingerprint(agentId),
              reason: route.reason,
            });
            warnings += 1;
            unresolvedFinished += 1;
            continue;
          }
          this.store.setWatermark(serverId, agentId, timestamp.iso);
          watermarks += 1;
          continue;
        }
        if (timestamp.ms <= Date.parse(watermark)) continue;
        if (permissionIds.length > 0) continue;

        if (!route.ok) {
          // Newer finished with missing workspace authority must not mark the watermark.
          this.logger.warn("finished_route_unresolved", {
            agentFp: fingerprint(agentId),
            reason: route.reason,
          });
          warnings += 1;
          unresolvedFinished += 1;
          continue;
        }

        this.store.upsertItem({
          serverId,
          agentId,
          workspaceId: route.workspaceId,
          kind: "finished",
          eventTimestamp: timestamp.iso,
          eventMs: timestamp.ms,
          status: "pending",
          deadlineMs: timestamp.ms + this.finishedTtlMs,
          finishedTtlMs: this.finishedTtlMs,
        });
        this.store.setWatermark(serverId, agentId, timestamp.iso);
        finishedEnqueued += 1;
        watermarks += 1;
      }

      if (pruneMissing && !isFirstRun) {
        for (const item of this.store.listItems()) {
          if (item.serverId === serverId && !seenKeys.has(item.agentKey)) {
            this.store.markAgentMissing(item.serverId, item.agentId);
          }
        }
        for (const pending of this.store.listPendingAuthority()) {
          const key = agentKey({ serverId: pending.serverId, agentId: pending.agentId });
          if (pending.serverId === serverId && !seenKeys.has(key)) {
            this.store.markAgentMissing(pending.serverId, pending.agentId);
          }
        }
      }
      if (isFirstRun) this.store.markInitialized(serverId);
    });

    const unresolved = unresolvedPermissions + unresolvedFinished;
    this.logger.info("reconcile_done", {
      firstRun: isFirstRun,
      agents: agents.length,
      workspaces: workspaceIds.size,
      watermarks,
      permissions,
      finishedEnqueued,
      warnings,
      unresolved,
      unresolvedPermissions,
      unresolvedFinished,
    });
    return {
      watermarks,
      permissions,
      finishedEnqueued,
      warnings,
      unresolved,
      unresolvedPermissions,
      unresolvedFinished,
      displayNames,
      seenKeys,
    };
  }

  /** Persist the attention trigger before any authority RPC. */
  async recordAttention(event) {
    return this.store.transaction(() => this.store.recordPendingAttention(event));
  }

  /** Complete one persisted attention only after authoritative route resolution. */
  async resolveAttention(input) {
    return this.store.transaction(() => {
      const event = this.store.getPendingAuthority(input.eventFp);
      if (!event) {
        return { enqueued: false, reason: this.store.hasProcessedEvent(input.eventFp) ? "dedup" : "missing" };
      }
      if (event.reason === "permission") {
        if (!input.permissionRequestIds?.length) return { enqueued: false, reason: "permission-ids-pending" };
        this.store.syncPermissionSet(event.serverId, event.agentId, input.workspaceId, input.permissionRequestIds, {
          eventTimestamp: event.timestamp,
          eventMs: event.eventMs,
        });
      } else {
        this.store.upsertItem({
          serverId: event.serverId,
          agentId: event.agentId,
          workspaceId: input.workspaceId,
          kind: "finished",
          eventTimestamp: event.timestamp,
          eventMs: event.eventMs,
          status: "pending",
          deadlineMs: event.eventMs + this.finishedTtlMs,
          finishedTtlMs: this.finishedTtlMs,
        });
        this.store.setWatermark(event.serverId, event.agentId, event.timestamp);
      }
      this.store.completePendingAttention(input.eventFp);
      return { enqueued: true, reason: event.reason };
    });
  }

  async scheduleAuthorityRetry(eventFp, options) {
    return this.store.transaction(() => this.store.schedulePendingAuthority(eventFp, options));
  }

  async handlePermissionResolved(serverId, agentId, requestId) {
    return this.store.transaction(() => this.store.resolvePermissionId(serverId, agentId, requestId));
  }

  /** Correlation only: never creates or delivers a popup. */
  async handlePermissionRequest(serverId, agentId, requestId) {
    return this.store.transaction(() => ({
      correlated: true,
      ids: this.store.addPermissionCorrelation(serverId, agentId, requestId),
    }));
  }

  async handleAgentDeleted(serverId, agentId) {
    return this.store.transaction(() => ({ removed: this.store.markAgentMissing(serverId, agentId) }));
  }
}
