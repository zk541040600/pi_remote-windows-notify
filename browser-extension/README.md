# Pi Notify browser extension (Chrome / Edge)

Shared Manifest V3 extension core for **exact** Pi Web notification activation.

## Contract (external-only)

- Configurable trusted Pi Web origins → `instanceKey`
- Startup tab enumeration + `tabs` / `webNavigation` URL tracking
- Live owner only when URL is trusted **and** has a valid `?session=`
- `routingKey = SHA-256("pi-web-route-v1\\0" + instanceKey + "\\0" + rawSessionId)` (full 256-bit hex)
- `profileKey` / `pageKey` / runtime `tabId`/`windowId`; atomic unregister/register on change
- Native Messaging host: `io.pi.notify.route` with reconnect
- **Poll-activation protocol** (primary):
  1. Service worker periodically sends `poll-activation` with `adapterKey` (single-flight, pauses while disconnected, does not overlap heartbeat)
  2. `ok` / `no-pending` → no-op
  3. `ready` → convert to activate command (`activationRequestId`, `notificationId`, `snapshotId`, owner/page/instance/routing/pageFingerprint/deadline)
  4. Focus window+tab, re-read URL → `activate-result` with **`activationRequestId`** so daemon `activation-status` reaches a final result
- **Host wake frames** (MV3 idle fix): after caller-origin allowlist validation, the Native Messaging relay emits bounded unsolicited `{type:"wake", protocolVersion, seq}` frames (~1s). Only that exact schema/version with a positive integer sequence is actionable; polluted frames fail closed. A valid wake runs the existing single-flight `ActivationPoller.tick()` (no second activation path, timeout extension, or validation bypass). Lease maintenance is throttled and refreshes only owners whose current tab URL still proves the same route; normal wakes do not write logs or extension storage. Wake frames carry no session/URL/routing/token content and are never forwarded to the daemon.
- Activate validation: match frozen `pageKey` + `routingKey` + origin, focus window+tab, re-read URL → `session-url-confirmed` or `stale`
- **No** `webRequest`, `debugger`, required `<all_urls>`, or page-script injection
- Logs never include raw session IDs or full URLs

Same session with multiple live owners is **not** resolved here; Route Host returns `ambiguous`.

## Layout

```text
browser-extension/
  core/           # shared pure ESM (also imported by Node tests)
  src/            # background service worker, options page, crypto shim
  scripts/        # build + icon generator
  test/           # pure Node tests
  build/chrome/   # unpacked Chrome output
  build/edge/     # unpacked Edge output
```

## Build

```bash
cd browser-extension
npm test
npm run build
```

Load unpacked:

- Chrome: `chrome://extensions` → Developer mode → Load unpacked → `build/chrome`
- Edge: `edge://extensions` → Developer mode → Load unpacked → `build/edge`

Then open extension options, add trusted origin + `instanceKey`, and **Request host permissions**.
Loading/configuring must be repeated and verified separately for Chrome and Edge; building the
artifacts or registering the Native Messaging host does not activate either browser adapter.

To upgrade, rebuild and use the browser's **Reload** action for the same unpacked directory, then
confirm the adapter and owner leases re-register before generating a new notification. To disable
or uninstall, remove/unload the extension in that browser profile; existing notification snapshots
then fail closed as `adapter-unavailable`/`stale` and must never fall back to another browser or
Terminal.

## Native Messaging

Host name: `io.pi.notify.route`
Installer (outside this directory) must register the host under:

- Chrome: `HKCU\Software\Google\Chrome\NativeMessagingHosts\io.pi.notify.route`
- Edge: `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\io.pi.notify.route`

`allowed_origins` must list the real extension IDs after load.

## Config storage keys

| Key | Meaning |
|-----|---------|
| `profileKey` | Stable per browser profile installation |
| `trustedOrigins` | `[{ origin, instanceKey }, ...]` |
| `leaseTtlMs` | Owner/adapter lease TTL (1s–120s) |
| `adapterKey` | Runtime adapter identity for Route Host |
| `browserKind` | `chrome` \| `edge` |

## Tests

```bash
node --test test/*.test.mjs
```

Coverage: URL parsing, routingKey vectors, owner state transitions, multi-owner metadata, reconnect policy, activation validation, poll-activation (no-pending / ready / result correlation / disconnect / single-flight / duplicate), log redaction.
