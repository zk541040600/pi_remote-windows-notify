import {
  eventFingerprint,
  normalizeOpaqueId,
  parseAttentionTimestamp,
  sanitizeText,
} from "./privacy.mjs";

/**
 * Shared parent Windows v1 contract fixture shape.
 * @typedef {object} PaseoNotifyV1Payload
 * @property {"paseo"} originKind
 * @property {string} notificationId
 * @property {"finished" | "permission"} notificationKind
 * @property {string} title
 * @property {string} body
 * @property {{ version: 1, serverId: string, workspaceId: string, agentId: string }} paseoRoute
 */

/**
 * @typedef {object} AttentionEvent
 * @property {string} agentId
 * @property {"finished" | "error" | "permission"} reason
 * @property {string} timestamp
 * @property {boolean} [shouldNotify]
 * @property {{ title?: string, body?: string, data?: { serverId?: string, workspaceId?: string, agentId?: string, reason?: string } }} [notification]
 */

/**
 * Provider-neutral normalize. No provider switch.
 * @param {AttentionEvent} event
 * @param {{ serverId: string, now?: number }} ctx
 * @returns {{ ok: true, reason: "finished" | "permission", agentId: string, timestamp: string, eventMs: number, eventFp: string } | { ok: false, drop: true, reason: string }}
 */
export function normalizeAttentionEvent(event, ctx) {
  if (!event || typeof event !== "object") {
    return { ok: false, drop: true, reason: "shape" };
  }
  if (event.reason === "error") {
    return { ok: false, drop: true, reason: "error" };
  }
  if (event.reason !== "finished" && event.reason !== "permission") {
    return { ok: false, drop: true, reason: "unknown-reason" };
  }

  const agentId = normalizeOpaqueId(event.agentId);
  if (!agentId) {
    return { ok: false, drop: true, reason: "agent-id" };
  }

  const serverId = normalizeOpaqueId(ctx.serverId);
  if (!serverId) {
    return { ok: false, drop: true, reason: "server-id" };
  }

  // Optional consistency check against notification.data.serverId — never replace authoritative serverId
  if (event.notification?.data?.serverId) {
    const dataServer = normalizeOpaqueId(event.notification.data.serverId);
    if (dataServer && dataServer !== serverId) {
      return { ok: false, drop: true, reason: "server-mismatch" };
    }
  }

  const ts = parseAttentionTimestamp(event.timestamp, { now: ctx.now });
  if (!ts.ok) {
    return { ok: false, drop: true, reason: `timestamp-${ts.reason}` };
  }

  // shouldNotify is intentionally ignored (R1)
  const eventFp = eventFingerprint({
    serverId,
    agentId,
    reason: event.reason,
    timestamp: ts.iso,
  });

  return {
    ok: true,
    reason: event.reason,
    agentId,
    timestamp: ts.iso,
    eventMs: ts.ms,
    eventFp,
  };
}

/**
 * Build minimal privacy-preserving Windows v1 payload.
 * @param {{
 *   notificationId: string,
 *   kind: "finished" | "permission",
 *   serverId: string,
 *   workspaceId: string,
 *   agentId: string,
 *   agentDisplayName?: string,
 *   detailedSummary?: boolean,
 *   summaryText?: string,
 *   titleMax?: number,
 *   bodyMax?: number,
 * }} input
 * @returns {PaseoNotifyV1Payload}
 */
export function buildNotifyPayload(input) {
  const titleMax = input.titleMax ?? 72;
  const bodyMax = input.bodyMax ?? 220;
  const displayName = sanitizeText(input.agentDisplayName || "Agent", "Agent", Math.min(48, titleMax));

  const title = sanitizeText(displayName, "Agent", titleMax);
  let body;
  if (input.kind === "finished") {
    body = input.detailedSummary && input.summaryText
      ? sanitizeText(input.summaryText, "已完成", bodyMax)
      : sanitizeText("已完成", "已完成", bodyMax);
  } else {
    body = input.detailedSummary && input.summaryText
      ? sanitizeText(input.summaryText, "等待授权", bodyMax)
      : sanitizeText("等待授权", "等待授权", bodyMax);
  }

  return {
    originKind: "paseo",
    notificationId: input.notificationId,
    notificationKind: input.kind,
    title,
    body,
    paseoRoute: {
      version: 1,
      serverId: input.serverId,
      workspaceId: input.workspaceId,
      agentId: input.agentId,
    },
  };
}

/**
 * Strict close v1 body — only these three fields.
 * @param {string} notificationId
 */
export function buildClosePayload(notificationId) {
  return {
    originKind: "paseo",
    version: 1,
    notificationId,
  };
}

/**
 * Validate route triple from authoritative snapshot fields.
 * @param {{ serverId: string, workspaceId: unknown, agentId: unknown }} parts
 */
export function validateRoute(parts) {
  const serverId = normalizeOpaqueId(parts.serverId);
  const workspaceId = normalizeOpaqueId(parts.workspaceId);
  const agentId = normalizeOpaqueId(parts.agentId);
  if (!serverId) return { ok: false, reason: "server-id" };
  if (!workspaceId) return { ok: false, reason: "workspace-id" };
  if (!agentId) return { ok: false, reason: "agent-id" };
  return { ok: true, serverId, workspaceId, agentId };
}

/**
 * Extract permission request IDs from authoritative pendingPermissions array.
 * Never uses array order to pick "latest".
 * @param {unknown} pendingPermissions
 * @returns {string[]}
 */
export function extractPermissionRequestIds(pendingPermissions) {
  if (!Array.isArray(pendingPermissions)) return [];
  const ids = [];
  for (const entry of pendingPermissions) {
    if (!entry || typeof entry !== "object") continue;
    const id = normalizeOpaqueId(/** @type {{ id?: unknown }} */ (entry).id);
    if (id) ids.push(id);
  }
  return [...new Set(ids)];
}

/**
 * Agent display name from snapshot title only (not for routing).
 * @param {{ title?: unknown, id?: unknown }} agent
 * @param {string} [fallback]
 */
export function agentDisplayName(agent, fallback = "Agent") {
  if (agent && typeof agent.title === "string" && agent.title.trim()) {
    return sanitizeText(agent.title, fallback, 48);
  }
  return fallback;
}
