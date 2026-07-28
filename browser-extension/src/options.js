/**
 * Options page: edit trusted origins + instanceKey; request explicit host permissions.
 */

import { loadConfig, saveConfig, configHostPermissions, normalizeConfig } from '../core/config.mjs';
import { normalizeOrigin } from '../core/url-session.mjs';

const BROWSER_KIND = globalThis.__PI_NOTIFY_BROWSER_KIND__ === 'edge' ? 'edge' : 'chrome';
const chromeApi = globalThis.chrome;

function storageLocal() {
  return {
    get: (keys) =>
      new Promise((resolve) => {
        chromeApi.storage.local.get(keys, (r) => resolve(r || {}));
      }),
    set: (items) =>
      new Promise((resolve) => {
        chromeApi.storage.local.set(items, () => resolve());
      }),
  };
}

/** @type {import('../core/config.mjs').ExtensionConfig} */
let config;

const els = {
  browserKind: document.getElementById('browserKind'),
  profileKey: document.getElementById('profileKey'),
  tbody: document.querySelector('#originTable tbody'),
  newOrigin: document.getElementById('newOrigin'),
  newInstance: document.getElementById('newInstance'),
  addBtn: document.getElementById('addBtn'),
  leaseTtl: document.getElementById('leaseTtl'),
  saveBtn: document.getElementById('saveBtn'),
  permBtn: document.getElementById('permBtn'),
  status: document.getElementById('status'),
};

function setStatus(text, ok = true) {
  els.status.textContent = text;
  els.status.style.color = ok ? '' : 'var(--danger)';
}

function render() {
  els.browserKind.textContent = config.browserKind;
  els.profileKey.textContent = config.profileKey;
  els.leaseTtl.value = String(config.leaseTtlMs);
  els.tbody.replaceChildren();

  for (const entry of config.trustedOrigins) {
    const tr = document.createElement('tr');
    const tdO = document.createElement('td');
    tdO.className = 'mono';
    tdO.textContent = entry.origin;
    const tdI = document.createElement('td');
    tdI.className = 'mono';
    tdI.textContent = entry.instanceKey;
    const tdA = document.createElement('td');
    const rm = document.createElement('button');
    rm.type = 'button';
    rm.className = 'danger';
    rm.textContent = 'Remove';
    rm.addEventListener('click', () => {
      config.trustedOrigins = config.trustedOrigins.filter((e) => e.origin !== entry.origin);
      render();
    });
    tdA.appendChild(rm);
    tr.append(tdO, tdI, tdA);
    els.tbody.appendChild(tr);
  }
}

els.addBtn.addEventListener('click', () => {
  const originRaw = String(els.newOrigin.value || '').trim();
  const instanceKey = String(els.newInstance.value || '').trim();
  const norm = normalizeOrigin(originRaw);
  if (!norm) {
    setStatus('Invalid origin (http/https only, no credentials).', false);
    return;
  }
  if (instanceKey.length < 8) {
    setStatus('instanceKey must be at least 8 characters.', false);
    return;
  }
  if (!/^[A-Za-z0-9._+-]+$/.test(instanceKey)) {
    setStatus('instanceKey has invalid characters.', false);
    return;
  }
  config.trustedOrigins = [
    ...config.trustedOrigins.filter((e) => e.origin !== norm.origin),
    { origin: norm.origin, instanceKey },
  ];
  els.newOrigin.value = '';
  els.newInstance.value = '';
  setStatus('Origin added (not saved yet).');
  render();
});

els.saveBtn.addEventListener('click', async () => {
  try {
    const lease = Number(els.leaseTtl.value);
    config.leaseTtlMs = Number.isFinite(lease) ? lease : config.leaseTtlMs;
    config.browserKind = BROWSER_KIND;
    config = await saveConfig(storageLocal(), config);
    setStatus('Saved. Service worker will reload trusted origins.');
    render();
  } catch (err) {
    setStatus(`Save failed: ${err?.message || err}`, false);
  }
});

els.permBtn.addEventListener('click', async () => {
  const perms = configHostPermissions(config);
  if (!perms.length) {
    setStatus('Add at least one trusted origin first.', false);
    return;
  }
  chromeApi.permissions.request({ origins: perms }, (granted) => {
    if (chromeApi.runtime.lastError) {
      setStatus(chromeApi.runtime.lastError.message || 'Permission request failed', false);
      return;
    }
    setStatus(granted ? `Granted: ${perms.join(', ')}` : 'Permissions not granted.', granted);
  });
});

async function init() {
  config = await loadConfig(storageLocal(), { browserKind: BROWSER_KIND });
  config = normalizeConfig(config, { browserKind: BROWSER_KIND });
  config.browserKind = BROWSER_KIND;
  render();
}

init().catch((err) => setStatus(String(err?.message || err), false));
