/**
 * MV3 service worker — Chrome/Edge shared.
 * Enumerates trusted Pi Web tabs, registers live owners, handles activate via Native Messaging.
 *
 * External-only contract:
 * - No webRequest, debugger, page script injection, or <all_urls>.
 * - Owner registration only when URL is trusted origin + valid ?session=.
 * - routingKey = SHA-256("pi-web-route-v1\\0" + instanceKey + "\\0" + rawSessionId).
 */

import { createHash, randomFillSync } from './shim-crypto.js';
import {
  NATIVE_HOST_NAME,
  DEFAULT_LEASE_TTL_MS,
  DEFAULT_POLL_INTERVAL_MS,
  MessageTypes,
  RouteResults,
} from '../core/protocol.mjs';
import { OwnerRegistry } from '../core/owner-registry.mjs';
import { NativePortClient } from '../core/native-port.mjs';
import { handleActivateCommand, parseActivateCommand } from '../core/activate.mjs';
import { ActivationPoller } from '../core/activation-poller.mjs';
import {
  isWakeMessage,
  dispatchWakeToPoller,
  recoverAdapterRegistration,
  refreshLiveOwnerLeases,
  shouldRunWakeMaintenance,
  validateWakeMessage,
} from '../core/wake.mjs';
import { createSafeLogger } from '../core/safe-log.mjs';
import {
  loadConfig,
  saveConfig,
  configToTrustedMap,
  emptyConfig,
  STORAGE_KEYS,
} from '../core/config.mjs';
import { newAdapterKey, ensureProfileKey } from '../core/ids.mjs';

// Node-compatible crypto hook used by core (routing-key / ids) inside the worker.
globalThis.__piNotifyNodeCrypto = {
  createHash: (alg) => {
    // Prefer Web Crypto via a tiny sync-incompatible path; use Subtle in async only.
    // For MV3 we polyfill createHash with a pure JS SHA-256 for sync callers.
    return createHash(alg);
  },
  randomFillSync: (buf) => randomFillSync(buf),
};

const BROWSER_KIND = globalThis.__PI_NOTIFY_BROWSER_KIND__ === 'edge' ? 'edge' : 'chrome';

const log = createSafeLogger();

/** @type {OwnerRegistry | null} */
let registry = null;
/** @type {NativePortClient | null} */
let native = null;
/** @type {ActivationPoller | null} */
let activationPoller = null;
/** @type {ReturnType<typeof setInterval> | null} */
let heartbeatTimer = null;
/** @type {string} */
let adapterKey = '';
/** @type {string} */
let profileKey = '';
/** Last wake-driven lease maintenance timestamp (ms). */
let lastWakeMaintenanceMs = 0;
/** Last invalid-wake warning timestamp; malformed host traffic must not flood logs. */
let lastInvalidWakeLogMs = Number.NEGATIVE_INFINITY;
/** Shared lease refresh promise prevents interval/wake overlap. */
let leaseRefreshPromise = null;
/** Shared daemon-state recovery promise prevents overlapping wake re-registration. */
let registrationRecoveryPromise = null;

const chromeApi = globalThis.chrome;

function storageLocal() {
  return {
    get: (keys) =>
      new Promise((resolve) => {
        chromeApi.storage.local.get(keys, (result) => resolve(result || {}));
      }),
    set: (items) =>
      new Promise((resolve) => {
        chromeApi.storage.local.set(items, () => resolve());
      }),
  };
}

function browserFocusApi() {
  return {
    tabsGet: (tabId) =>
      new Promise((resolve, reject) => {
        chromeApi.tabs.get(tabId, (tab) => {
          if (chromeApi.runtime.lastError) {
            reject(new Error(chromeApi.runtime.lastError.message));
            return;
          }
          resolve(tab);
        });
      }),
    tabsUpdate: (tabId, props) =>
      new Promise((resolve, reject) => {
        chromeApi.tabs.update(tabId, props, (tab) => {
          if (chromeApi.runtime.lastError) {
            reject(new Error(chromeApi.runtime.lastError.message));
            return;
          }
          resolve(tab);
        });
      }),
    windowsUpdate: (windowId, props) =>
      new Promise((resolve, reject) => {
        chromeApi.windows.update(windowId, props, (win) => {
          if (chromeApi.runtime.lastError) {
            reject(new Error(chromeApi.runtime.lastError.message));
            return;
          }
          resolve(win);
        });
      }),
    windowsGet: (windowId) =>
      new Promise((resolve, reject) => {
        chromeApi.windows.get(windowId, (win) => {
          if (chromeApi.runtime.lastError) {
            reject(new Error(chromeApi.runtime.lastError.message));
            return;
          }
          resolve(win);
        });
      }),
  };
}

/**
 * @param {Record<string, unknown>} msg
 */
async function sendToHost(msg) {
  if (!native || !native.isConnected) {
    throw new Error('native-port-disconnected');
  }
  return native.send(msg);
}

async function rebuildRegistryFromConfig() {
  const config = await loadConfig(storageLocal(), { browserKind: BROWSER_KIND });
  profileKey = ensureProfileKey(config.profileKey);

  if (!config.adapterKey) {
    adapterKey = newAdapterKey(BROWSER_KIND, profileKey);
    config.adapterKey = adapterKey;
    config.profileKey = profileKey;
    config.browserKind = BROWSER_KIND;
    await saveConfig(storageLocal(), config);
  } else {
    adapterKey = config.adapterKey;
  }

  const trusted = configToTrustedMap(config);

  if (registry) {
    await registry.clearAll('config-reload');
  }

  registry = new OwnerRegistry({
    browserKind: BROWSER_KIND,
    profileKey,
    adapterKey,
    trustedOrigins: trusted,
    leaseTtlMs: config.leaseTtlMs || DEFAULT_LEASE_TTL_MS,
    preferSyncRoutingKey: true,
    log,
    send: sendToHost,
  });

  log.info('registry-ready', {
    browserKind: BROWSER_KIND,
    originCount: config.trustedOrigins.length,
    profileFp: profileKey.slice(0, 12),
  });

  return config;
}

async function enumerateTabs() {
  if (!registry) return;
  const config = await loadConfig(storageLocal(), { browserKind: BROWSER_KIND });
  if (!config.trustedOrigins.length) {
    log.info('enumerate-skip', { reason: 'no-trusted-origins' });
    return;
  }

  await new Promise((resolve) => {
    chromeApi.tabs.query({}, async (tabs) => {
      try {
        for (const tab of tabs || []) {
          if (tab.id == null || tab.windowId == null) continue;
          await registry.observeTab({
            tabId: tab.id,
            windowId: tab.windowId,
            url: tab.url,
          });
        }
      } catch (err) {
        log.error('enumerate-error', { reason: err?.name || 'error' });
      }
      resolve();
    });
  });
}

/**
 * Refresh adapter + owner leases. Shared by the interval heartbeat and wake-driven
 * maintenance so MV3 idle does not let leases expire while the native host stays up.
 * @param {{ source?: string }} [opts]
 */
async function refreshLeases(opts = {}) {
  if (!registry || !native?.isConnected) return;
  if (leaseRefreshPromise) return leaseRefreshPromise;

  const activeRegistry = registry;
  const source = opts.source || 'heartbeat';
  leaseRefreshPromise = (async () => {
    // Activation has priority; the next bounded wake/interval will retry maintenance.
    if (activationPoller?.isInFlight) return;

    await activeRegistry.heartbeat();
    await refreshLiveOwnerLeases({
      registry: activeRegistry,
      tabsGet: (tabId) => browserFocusApi().tabsGet(tabId),
      shouldContinue: () => registry === activeRegistry && Boolean(native?.isConnected),
    });
  })()
    .catch((err) => {
      log.warn('heartbeat-failed', {
        reason: err?.message || 'error',
        source,
      });
    })
    .finally(() => {
      leaseRefreshPromise = null;
    });

  return leaseRefreshPromise;
}

/**
 * Rebuild daemon-side adapter/owner state after an authoritative adapter-unknown
 * response. A daemon restart clears leases but does not necessarily disconnect the
 * long-lived Chrome Native Messaging port, so the normal onConnectionChange handler
 * may never run.
 *
 * Owner recovery remains fail-closed: enumerateTabs only observes currently live
 * tabs, and OwnerRegistry registers only trusted origins with a valid session.
 *
 * @param {{ source?: string }} [opts]
 * @returns {Promise<{ action: string, ownerCount?: number, reason?: string }>}
 */
async function recoverRouteRegistrations(opts = {}) {
  if (!registry || !native?.isConnected) {
    return { action: 'skipped', reason: 'disconnected' };
  }
  if (registrationRecoveryPromise) return registrationRecoveryPromise;

  const activeRegistry = registry;
  const source = opts.source || 'adapter-state-lost';
  registrationRecoveryPromise = (async () => {
    const outcome = await recoverAdapterRegistration({
      registry: activeRegistry,
      enumerateTabs,
      isCurrent: () => registry === activeRegistry && Boolean(native?.isConnected),
    });
    if (outcome.action === 'recovered') {
      log.info('route-registration-recovered', {
        source,
        ownerCount: outcome.ownerCount ?? 0,
      });
    } else if (outcome.action === 'failed') {
      log.warn('route-registration-recovery-failed', {
        reason: outcome.reason || 'error',
        source,
      });
    }
    return outcome;
  })()
    .catch((err) => {
      log.warn('route-registration-recovery-failed', {
        reason: err?.message || 'error',
        source,
      });
      return { action: 'failed', reason: err?.message || 'error' };
    })
    .finally(() => {
      registrationRecoveryPromise = null;
    });

  return registrationRecoveryPromise;
}

function startHeartbeat() {
  if (heartbeatTimer != null) {
    clearInterval(heartbeatTimer);
  }
  heartbeatTimer = setInterval(() => {
    refreshLeases({ source: 'interval' }).catch(() => {});
  }, 15_000);
}

/**
 * Handle a host wake frame: force one existing ActivationPoller tick through the
 * single-flight gate. Does not create a second activation path or bypass validation.
 * Optionally runs bounded lease maintenance so owner/adapter leases stay fresh while
 * wakes keep the worker active.
 * @param {unknown} raw
 * @param {{ now?: () => number }} [opts]
 * @returns {Promise<{ action: string, result?: string, reason?: string } | null>}
 */
export async function handleWakeMessage(raw, opts = {}) {
  if (!isWakeMessage(raw)) return null;

  const now = (opts.now ?? Date.now)();
  const check = validateWakeMessage(raw);
  if (!check.ok) {
    if (now - lastInvalidWakeLogMs >= 60_000) {
      lastInvalidWakeLogMs = now;
      log.warn('wake-frame-invalid', { reason: check.reason });
    }
    return { action: 'skipped', reason: 'invalid-wake' };
  }

  const runMaintenance = shouldRunWakeMaintenance({
    lastMaintenanceMs: lastWakeMaintenanceMs,
    nowMs: now,
  });
  if (runMaintenance) lastWakeMaintenanceMs = now;

  // Poll first so lease work cannot consume the bounded activation deadline. The poller
  // remains the only activation path and enforces its existing single-flight gate.
  try {
    const out = await dispatchWakeToPoller(raw, ensureActivationPoller(), {
      validate: false,
      onAdapterStateLost: () =>
        recoverRouteRegistrations({ source: 'wake-adapter-unknown' }),
    });
    if (runMaintenance) await refreshLeases({ source: 'wake' });
    return out;
  } catch (err) {
    log.warn('wake-poll-tick-error', { reason: err?.message || 'error' });
    return { action: 'error', reason: err?.message || 'error' };
  }
}

function ensureActivationPoller() {
  if (activationPoller) return activationPoller;
  activationPoller = new ActivationPoller({
    getRegistry: () => registry,
    getPort: () =>
      native
        ? {
            send: (msg) => native.send(msg),
            post: (msg) => native.post(msg),
            get isConnected() {
              return native.isConnected;
            },
          }
        : null,
    browserApi: browserFocusApi(),
    log,
    intervalMs: DEFAULT_POLL_INTERVAL_MS,
    onActivateComplete: (outcome) => {
      log.info('poll-path-activate-complete', {
        result: outcome.result,
        reason: outcome.reason || '',
        activationFp: (outcome.activationRequestId || '').slice(0, 12),
        elapsedMs: outcome.elapsedMs,
      });
    },
  });
  return activationPoller;
}

function connectNative() {
  if (native) {
    native.stop();
    native = null;
  }

  ensureActivationPoller();

  native = new NativePortClient({
    runtime: {
      connectNative: (name) => chromeApi.runtime.connectNative(name),
      get lastError() {
        return chromeApi.runtime.lastError;
      },
    },
    hostName: NATIVE_HOST_NAME,
    log,
    onMessage: async (msg) => {
      await onNativeMessage(msg);
    },
    onConnectionChange: async (connected, meta) => {
      log.info('native-connection', { connected, reason: meta?.reason || '' });
      if (connected && registry) {
        try {
          await registry.registerAdapter();
          await enumerateTabs();
          // Kick one poll immediately after reconnect; regular interval continues.
          if (activationPoller?.isRunning) {
            activationPoller.tick().catch(() => {});
          }
        } catch (err) {
          log.warn('post-connect-register-failed', { reason: err?.message || 'error' });
        }
      }
      // Poller remains started but ticks no-op while disconnected (fail-closed).
    },
  });
  native.start();
}

/**
 * @param {unknown} raw
 */
async function onNativeMessage(raw) {
  if (!raw || typeof raw !== 'object') return;
  const msg = /** @type {Record<string, unknown>} */ (raw);

  // Unsolicited host wake: inbound Native Messaging traffic wakes this MV3 worker.
  // Force one existing poller tick; do not treat wake as a route command.
  if (isWakeMessage(msg)) {
    await handleWakeMessage(msg);
    return;
  }

  if (msg.type === MessageTypes.Activate || msg.type === 'activate') {
    await onActivate(msg);
  }
}

/**
 * Legacy push-style activate (if host ever delivers type=activate on the port).
 * Poll path is primary; this remains for compatibility and uses activationRequestId when present.
 * @param {Record<string, unknown>} raw
 */
async function onActivate(raw) {
  if (!registry) {
    log.warn('activate-no-registry', {});
    return;
  }

  // Avoid racing with the poller single-flight gate.
  if (activationPoller?.isInFlight) {
    log.warn('activate-push-skipped', { reason: 'poll-in-flight' });
    return;
  }

  const command = parseActivateCommand(raw);
  if (!command) {
    log.warn('activate-parse-failed', {});
    return;
  }

  const outcome = await handleActivateCommand({
    registry,
    browserApi: browserFocusApi(),
    command,
    log,
  });

  const resultMsg = registry.buildActivateResult({
    requestId: command.requestId,
    activationRequestId: command.activationRequestId || command.requestId,
    notificationId: command.notificationId,
    snapshotId: command.snapshotId,
    result: outcome.result,
    reason: outcome.reason,
    elapsedMs: outcome.elapsedMs,
  });

  // The result envelope keeps its generated requestId. Reusing the activate requestId would hit
  // daemon replay protection; activationRequestId is the authoritative correlation field.

  try {
    if (native?.isConnected) {
      native.post(resultMsg);
    }
  } catch (err) {
    log.error('activate-result-send-failed', { reason: err?.message || 'error' });
  }

  log.info('activate-complete', {
    result: outcome.result,
    reason: outcome.reason || '',
    activationFp: (command.activationRequestId || command.requestId).slice(0, 12),
    elapsedMs: outcome.elapsedMs,
  });
}

function wireTabListeners() {
  chromeApi.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    // Prefer URL changes; also handle complete status when URL already present.
    if (changeInfo.url == null && changeInfo.status !== 'complete') return;
    if (!registry) return;
    const url = changeInfo.url ?? tab?.url;
    const windowId = tab?.windowId;
    if (windowId == null) return;
    registry
      .observeTab({ tabId, windowId, url })
      .catch((err) => log.warn('tab-updated-error', { reason: err?.message || 'error' }));
  });

  chromeApi.tabs.onRemoved.addListener((tabId) => {
    if (!registry) return;
    registry
      .removeTab(tabId)
      .catch((err) => log.warn('tab-removed-error', { reason: err?.message || 'error' }));
  });

  chromeApi.tabs.onAttached.addListener((tabId, attachInfo) => {
    if (!registry) return;
    chromeApi.tabs.get(tabId, (tab) => {
      if (chromeApi.runtime.lastError || !tab) return;
      registry
        .observeTab({
          tabId,
          windowId: attachInfo.newWindowId ?? tab.windowId,
          url: tab.url,
        })
        .catch(() => {});
    });
  });

  if (chromeApi.webNavigation?.onHistoryStateUpdated) {
    chromeApi.webNavigation.onHistoryStateUpdated.addListener((details) => {
      if (details.frameId !== 0) return;
      if (!registry) return;
      chromeApi.tabs.get(details.tabId, (tab) => {
        if (chromeApi.runtime.lastError || !tab) return;
        registry
          .observeTab({
            tabId: details.tabId,
            windowId: tab.windowId,
            url: details.url || tab.url,
            explicitOpen: true,
          })
          .catch(() => {});
      });
    });
  }

  if (chromeApi.webNavigation?.onCommitted) {
    chromeApi.webNavigation.onCommitted.addListener((details) => {
      if (details.frameId !== 0) return;
      if (!registry) return;
      chromeApi.tabs.get(details.tabId, (tab) => {
        if (chromeApi.runtime.lastError || !tab) return;
        registry
          .observeTab({
            tabId: details.tabId,
            windowId: tab.windowId,
            url: details.url || tab.url,
            explicitOpen: true,
          })
          .catch(() => {});
      });
    });
  }
}

chromeApi.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if (
    changes[STORAGE_KEYS.trustedOrigins] ||
    changes[STORAGE_KEYS.leaseTtlMs] ||
    changes[STORAGE_KEYS.browserKind]
  ) {
    rebuildRegistryFromConfig()
      .then(() => {
        if (native?.isConnected) {
          return registry?.registerAdapter().then(() => enumerateTabs());
        }
        return undefined;
      })
      .catch((err) => log.error('config-reload-error', { reason: err?.message || 'error' }));
  }
});

chromeApi.runtime.onInstalled.addListener(() => {
  log.info('extension-installed', { browserKind: BROWSER_KIND });
});

chromeApi.runtime.onStartup.addListener(() => {
  log.info('extension-startup', { browserKind: BROWSER_KIND });
});

async function main() {
  try {
    // Ensure at least an empty config exists so options page can edit it.
    const existing = await loadConfig(storageLocal(), { browserKind: BROWSER_KIND });
    if (!existing.profileKey) {
      await saveConfig(storageLocal(), emptyConfig(BROWSER_KIND));
    }

    await rebuildRegistryFromConfig();
    wireTabListeners();
    connectNative();
    startHeartbeat();
    ensureActivationPoller().start();

    // Initial enumerate even if native not yet up (local state); re-sent on connect.
    await enumerateTabs();
  } catch (err) {
    log.error('main-init-failed', { reason: err?.message || 'error' });
  }
}

main();

// Export for tests when imported under Node (optional).
export const __test = {
  get registry() {
    return registry;
  },
  get native() {
    return native;
  },
  get activationPoller() {
    return activationPoller;
  },
  get lastWakeMaintenanceMs() {
    return lastWakeMaintenanceMs;
  },
  set lastWakeMaintenanceMs(v) {
    lastWakeMaintenanceMs = v;
  },
  rebuildRegistryFromConfig,
  enumerateTabs,
  onActivate,
  onNativeMessage,
  ensureActivationPoller,
  handleWakeMessage,
  isWakeMessage,
  refreshLeases,
  recoverRouteRegistrations,
  RouteResults,
  MessageTypes,
};
