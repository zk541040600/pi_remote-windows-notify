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

function startHeartbeat() {
  if (heartbeatTimer != null) {
    clearInterval(heartbeatTimer);
  }
  heartbeatTimer = setInterval(async () => {
    if (!registry || !native?.isConnected) return;
    // Do not overlap with an in-flight poll/activate cycle (single-flight coordination).
    if (activationPoller?.isInFlight) {
      log.debug?.('heartbeat-skipped', { reason: 'poll-in-flight' });
      return;
    }
    try {
      await registry.heartbeat();
      // Refresh owner leases by re-registering known tabs lightly.
      for (const owner of registry.listOwners()) {
        try {
          const tab = await browserFocusApi().tabsGet(owner.tabId);
          await registry.observeTab({
            tabId: owner.tabId,
            windowId: tab?.windowId ?? owner.windowId,
            url: tab?.url,
          });
        } catch {
          await registry.removeTab(owner.tabId);
        }
      }
    } catch (err) {
      log.warn('heartbeat-failed', { reason: err?.message || 'error' });
    }
  }, 15_000);
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

  // Preserve the inbound requestId for correlation; activationRequestId is authoritative for daemon status.
  resultMsg.requestId = command.requestId;
  resultMsg.activationRequestId = command.activationRequestId || command.requestId;

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
  rebuildRegistryFromConfig,
  enumerateTabs,
  onActivate,
  ensureActivationPoller,
  RouteResults,
};
