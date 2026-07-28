/**
 * Activate command handling: focus window+tab, re-read URL, ack session-url-confirmed or stale.
 * No title guessing, no UIAutomation, no CDP, no webRequest.
 */

import { MessageTypes, RouteResults, RejectReasons } from './protocol.mjs';
import { fingerprintRoutingKey } from './routing-key.mjs';

/**
 * @typedef {import('./owner-registry.mjs').OwnerRegistry} OwnerRegistry
 * @typedef {import('./owner-registry.mjs').OwnerRecord} OwnerRecord
 *
 * @typedef {{
 *   tabsGet: (tabId: number) => Promise<{ id?: number, windowId?: number, url?: string, active?: boolean } | undefined>,
 *   tabsUpdate: (tabId: number, props: { active: boolean }) => Promise<unknown>,
 *   windowsUpdate: (windowId: number, props: { focused: boolean, drawAttention?: boolean }) => Promise<unknown>,
 *   windowsGet?: (windowId: number) => Promise<{ id?: number, focused?: boolean } | undefined>,
 * }} BrowserFocusApi
 *
 * @typedef {{
 *   requestId: string,
 *   activationRequestId?: string,
 *   notificationId?: string,
 *   snapshotId?: string,
 *   ownerKey?: string,
 *   pageKey: string,
 *   instanceKey: string,
 *   routingKey: string,
 *   pageFingerprint?: string,
 *   deadlineMs?: number,
 * }} ActivateCommand
 */

/**
 * Execute an activate command against the local registry and browser APIs.
 * @param {{
 *   registry: OwnerRegistry,
 *   browserApi: BrowserFocusApi,
 *   command: ActivateCommand,
 *   now?: () => number,
 *   log?: { info: Function, warn: Function, error: Function },
 * }} args
 * @returns {Promise<{ result: string, reason?: string, elapsedMs: number }>}
 */
export async function handleActivateCommand(args) {
  const started = (args.now ?? Date.now)();
  const { registry, browserApi, command, log } = args;
  const logger = log ?? { info() {}, warn() {}, error() {} };

  const elapsed = () => (args.now ?? Date.now)() - started;

  if (command.deadlineMs && (args.now ?? Date.now)() > command.deadlineMs) {
    return { result: RouteResults.Timeout, reason: RejectReasons.Expired, elapsedMs: elapsed() };
  }

  const validation = registry.validateActivateTarget(command);
  if (!validation.ok) {
    logger.warn('activate-validate-failed', {
      result: validation.result,
      reason: validation.reason,
      routingFp: fingerprintRoutingKey(command.routingKey),
      requestId: command.requestId?.slice?.(0, 12) ?? '',
    });
    return { result: validation.result, reason: validation.reason, elapsedMs: elapsed() };
  }

  const owner = validation.owner;

  // Re-read tab before focus — handles close/navigation races.
  let tab;
  try {
    tab = await browserApi.tabsGet(owner.tabId);
  } catch {
    tab = undefined;
  }

  if (!tab || tab.id == null) {
    await registry.removeTab(owner.tabId);
    return { result: RouteResults.Stale, reason: RejectReasons.TabMissing, elapsedMs: elapsed() };
  }

  // Confirm URL still matches before focusing (fail-closed).
  const preConfirm = await registry.confirmLiveUrl(owner, tab.url);
  if (!preConfirm.ok) {
    // Local registry is stale relative to live tab URL — drop owner.
    await registry.removeTab(owner.tabId);
    return { result: preConfirm.result, reason: preConfirm.reason, elapsedMs: elapsed() };
  }

  const alreadyActive = tab.active === true;
  let windowAlreadyFocused = false;
  if (browserApi.windowsGet) {
    try {
      const win = await browserApi.windowsGet(owner.windowId);
      windowAlreadyFocused = win?.focused === true;
    } catch {
      windowAlreadyFocused = false;
    }
  }

  try {
    await browserApi.windowsUpdate(owner.windowId, { focused: true });
  } catch {
    return {
      result: RouteResults.ForegroundDenied,
      reason: RejectReasons.WindowMissing,
      elapsedMs: elapsed(),
    };
  }

  try {
    await browserApi.tabsUpdate(owner.tabId, { active: true });
  } catch {
    return {
      result: RouteResults.SelectFailed,
      reason: RejectReasons.TabMissing,
      elapsedMs: elapsed(),
    };
  }

  // Re-read URL after focus; must still be target session.
  let postTab;
  try {
    postTab = await browserApi.tabsGet(owner.tabId);
  } catch {
    postTab = undefined;
  }

  if (!postTab?.url) {
    return { result: RouteResults.Stale, reason: RejectReasons.SessionUnresolved, elapsedMs: elapsed() };
  }

  const postConfirm = await registry.confirmLiveUrl(owner, postTab.url);
  if (!postConfirm.ok) {
    await registry.removeTab(owner.tabId);
    return { result: postConfirm.result, reason: postConfirm.reason, elapsedMs: elapsed() };
  }

  // Update windowId if browser moved the tab (still same pageKey/routingKey).
  if (typeof postTab.windowId === 'number' && postTab.windowId !== owner.windowId) {
    owner.windowId = postTab.windowId;
  }
  owner.lastSeenAtMs = (args.now ?? Date.now)();

  logger.info('activate-confirmed', {
    result: RouteResults.SessionUrlConfirmed,
    routingFp: fingerprintRoutingKey(owner.routingKey),
    ownerFp: owner.ownerKey.slice(0, 12),
    pageFp: owner.pageKey.slice(0, 12),
    tabId: owner.tabId,
    alreadyActive: alreadyActive && windowAlreadyFocused,
    elapsedMs: elapsed(),
  });

  if (alreadyActive && windowAlreadyFocused) {
    return {
      result: RouteResults.SessionUrlConfirmed,
      reason: 'already-active',
      elapsedMs: elapsed(),
    };
  }

  return {
    result: RouteResults.SessionUrlConfirmed,
    elapsedMs: elapsed(),
  };
}

/**
 * Normalize a raw native/host activate message into ActivateCommand.
 * Accepts both push-style `type=activate` and polled `result=ready` envelopes.
 * @param {Record<string, unknown>} raw
 * @returns {ActivateCommand | null}
 */
export function parseActivateCommand(raw) {
  if (!raw || typeof raw !== 'object') return null;

  const isPushActivate = raw.type === MessageTypes.Activate || raw.type === 'activate';
  const isPollReady =
    (raw.type === MessageTypes.Result ||
      raw.type === MessageTypes.PollActivation ||
      raw.type === 'result' ||
      raw.type === MessageTypes.Activate ||
      !raw.type) &&
    raw.result === RouteResults.Ready;

  if (!isPushActivate && !isPollReady) return null;

  // Prefer activationRequestId for final activate-result correlation (poll path).
  const activationRequestId =
    typeof raw.activationRequestId === 'string' && raw.activationRequestId
      ? raw.activationRequestId
      : undefined;
  const requestId =
    activationRequestId ||
    (typeof raw.requestId === 'string' && raw.requestId ? raw.requestId : '');
  if (!requestId) return null;

  if (typeof raw.pageKey !== 'string' || !raw.pageKey) return null;
  if (typeof raw.routingKey !== 'string' || !raw.routingKey) return null;
  if (typeof raw.instanceKey !== 'string' || !raw.instanceKey) return null;

  return {
    requestId,
    activationRequestId: activationRequestId || requestId,
    notificationId: typeof raw.notificationId === 'string' ? raw.notificationId : undefined,
    snapshotId: typeof raw.snapshotId === 'string' ? raw.snapshotId : undefined,
    ownerKey: typeof raw.ownerKey === 'string' ? raw.ownerKey : undefined,
    pageKey: raw.pageKey,
    instanceKey: raw.instanceKey,
    routingKey: raw.routingKey,
    pageFingerprint: typeof raw.pageFingerprint === 'string' ? raw.pageFingerprint : undefined,
    deadlineMs: typeof raw.deadlineMs === 'number' ? raw.deadlineMs : undefined,
  };
}

/**
 * Parse a poll-activation response. Returns:
 * - `{ kind: 'ready', command }` when a command must be activated
 * - `{ kind: 'no-pending' }` when nothing is queued (ok/no-pending)
 * - `{ kind: 'error', result, reason }` for fail-closed host errors
 * - null when the payload is not a poll response
 *
 * @param {Record<string, unknown>} raw
 * @returns {
 *   | { kind: 'ready', command: ActivateCommand }
 *   | { kind: 'no-pending' }
 *   | { kind: 'error', result: string, reason?: string }
 *   | null
 * }
 */
export function parsePollActivationResponse(raw) {
  if (!raw || typeof raw !== 'object') return null;

  const result = typeof raw.result === 'string' ? raw.result : '';
  if (!result) return null;

  if (result === RouteResults.Ready) {
    const command = parseActivateCommand({
      ...raw,
      // Ensure parseActivateCommand accepts this envelope as poll-ready.
      result: RouteResults.Ready,
      type: typeof raw.type === 'string' ? raw.type : MessageTypes.Result,
    });
    if (!command) {
      return {
        kind: 'error',
        result: RouteResults.Rejected,
        reason: RejectReasons.MissingField,
      };
    }
    return { kind: 'ready', command };
  }

  if (result === RouteResults.Ok && raw.reason === RejectReasons.NoPending) {
    return { kind: 'no-pending' };
  }

  // Host may also return ok without reason for empty queue; treat as no-pending.
  if (result === RouteResults.Ok && (raw.reason == null || raw.reason === '')) {
    return { kind: 'no-pending' };
  }

  // Fail-closed: adapter-unavailable, rejected, stale, etc.
  return {
    kind: 'error',
    result,
    reason: typeof raw.reason === 'string' ? raw.reason : undefined,
  };
}

/**
 * Whether a poll response indicates no work (safe no-op).
 * @param {Record<string, unknown>} raw
 * @returns {boolean}
 */
export function isNoPendingPollResult(raw) {
  const parsed = parsePollActivationResponse(raw);
  return parsed?.kind === 'no-pending';
}
