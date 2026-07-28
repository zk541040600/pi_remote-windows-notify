#!/usr/bin/env node
/**
 * Build Chrome and Edge unpacked extension directories from shared core + src.
 * Usage: node scripts/build.mjs
 */

import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');
const version = '0.1.0';
const extensionKey = readFileSync(join(root, 'extension-public-key.txt'), 'utf8').trim();
const extensionId = [...createHash('sha256').update(Buffer.from(extensionKey, 'base64')).digest('hex').slice(0, 32)]
  .map((nibble) => String.fromCharCode('a'.charCodeAt(0) + Number.parseInt(nibble, 16)))
  .join('');

/**
 * @param {'chrome' | 'edge'} browserKind
 */
function buildManifest(browserKind) {
  const name =
    browserKind === 'edge' ? 'Pi Notify Route (Edge)' : 'Pi Notify Route (Chrome)';
  const description =
    'Exact Pi Web session owner registration and notification tab activation via Native Messaging.';

  return {
    manifest_version: 3,
    name,
    version,
    // Stable public key keeps the unpacked extension ID deterministic across rebuilds.
    key: extensionKey,
    description,
    minimum_chrome_version: '109',
    icons: {
      16: 'icons/icon16.png',
      48: 'icons/icon48.png',
      128: 'icons/icon128.png',
    },
    action: {
      default_title: name,
      default_popup: '',
      default_icon: {
        16: 'icons/icon16.png',
        48: 'icons/icon48.png',
      },
    },
    background: {
      service_worker: 'background.js',
      type: 'module',
    },
    options_ui: {
      page: 'options.html',
      open_in_tab: true,
    },
    permissions: ['tabs', 'storage', 'nativeMessaging', 'webNavigation'],
    // Optional only — user grants specific Pi Web origins from the options page.
    // Not the same as required host_permissions / <all_urls>.
    optional_host_permissions: ['http://*/*', 'https://*/*'],
    // Content scripts intentionally omitted (no page injection).
  };
}

/**
 * @param {'chrome' | 'edge'} browserKind
 */
function buildBrowser(browserKind) {
  const out = join(root, 'build', browserKind);
  if (existsSync(out)) {
    rmSync(out, { recursive: true, force: true });
  }
  mkdirSync(out, { recursive: true });
  mkdirSync(join(out, 'icons'), { recursive: true });

  // Core modules
  cpSync(join(root, 'core'), join(out, 'core'), { recursive: true });

  // Static assets from src
  for (const file of ['options.html', 'options.css', 'options.js', 'shim-crypto.js']) {
    cpSync(join(root, 'src', file), join(out, file));
  }

  // Icons
  const iconSrc = join(root, 'icons');
  if (existsSync(iconSrc)) {
    cpSync(iconSrc, join(out, 'icons'), { recursive: true });
  }

  // background.js with browser kind banner
  const bg = readFileSync(join(root, 'src', 'background.js'), 'utf8');
  const banner = `globalThis.__PI_NOTIFY_BROWSER_KIND__ = ${JSON.stringify(browserKind)};\n`;
  // Fix imports: source uses ../core → build uses ./core
  const patched = banner + bg
    .replaceAll("from '../core/", "from './core/")
    .replaceAll("from './shim-crypto.js'", "from './shim-crypto.js'");
  writeFileSync(join(out, 'background.js'), patched);

  // options.js import paths
  const opt = readFileSync(join(root, 'src', 'options.js'), 'utf8');
  const optBanner = `globalThis.__PI_NOTIFY_BROWSER_KIND__ = ${JSON.stringify(browserKind)};\n`;
  writeFileSync(
    join(out, 'options.js'),
    optBanner + opt.replaceAll("from '../core/", "from './core/"),
  );

  writeFileSync(join(out, 'manifest.json'), JSON.stringify(buildManifest(browserKind), null, 2) + '\n');

  // Build identity file for install docs
  writeFileSync(
    join(out, 'BUILD_INFO.json'),
    JSON.stringify(
      {
        browserKind,
        version,
        nativeHostName: 'io.pi.notify.route',
        extensionId,
        builtAt: new Date().toISOString(),
      },
      null,
      2,
    ) + '\n',
  );

  console.log(`built ${browserKind} -> ${out}`);
}

buildBrowser('chrome');
buildBrowser('edge');
