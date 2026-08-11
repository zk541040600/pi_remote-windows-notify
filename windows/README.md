# Remote Pi → Windows Notify Bridge

This folder implements a reliable **Windows local notification bridge** for running Pi on remote host `my` while still receiving desktop notifications on Windows.

## Files

- `NotifyBridge.Common.ps1` — shared config, path, argument quoting, and toast setup helpers
- `NotifyBridge.Process.ps1` — shared detached-start and instance-owned process helpers
- `NotifyBridge.Remote.ps1` — shared remote path, SSH probe, and in-memory upload helpers
- `notify-listener.ps1` — Windows local HTTP listener that shows toast notifications
- `pi-notify-qq-sender.ps1` — optional bounded QQ mirror worker invoked only by the accepted listener path
- `pi-notify-broker.ps1` — long-lived low-latency WinForms broker for popup-focus mode (loopback HTTP on port 23119)
- `pi-notify-popup.ps1` — fallback per-notification popup process used when the broker is unavailable or disabled
- `pi-notify-reverse-tunnel.ps1` — persistent reverse SSH tunnel with auto-reconnect
- `pi-notify-watchdog.ps1` — self-heal watchdog for listener/tunnel/broker health
- `pi-notify-hotkey.ps1` — one-shot target activation used by the Start Menu global shortcut
- `set-notify-mode.ps1` — switch between `system-toast` and `popup-focus`
- `install-remote-windows-notify.ps1` — installs the remote Pi extension + config
- `install-windows-autostart.ps1` — registers Startup-folder launchers for listener/broker/tunnel/watchdog and removes legacy scheduled tasks
- `install-linux-autostart.ps1` — installs Linux systemd boot-time remote guard on `my`
- `install-autostart-all.ps1` — one-shot installer for both Windows + Linux autostart
- `remote-windows-notify.ts` — Pi extension template installed on the remote host
- `pi-notify-ensure.mjs` — atomic package/standalone ownership, config restore, and read-only drift check on the remote host
- `route-host/` — .NET current-user exact-route daemon, client, and Chromium Native Messaging relay
- `test-route.ps1` — Windows PowerShell 5.1 route metadata and fail-closed decision regression (includes Paseo contracts)
- `paseo-desktop-route.ps1` — loopback-only Paseo CDP controller (event dispatch; no Page.navigate)
- `set-paseo-desktop-routing.ps1` — explicit user-confirmed Enable/Disable helper for persistent `PASEO_ELECTRON_FLAGS` + config flag (never auto-run by install/refresh)
- `set-paseo-built-in-notifications.ps1` — explicit user-confirmed Disable/Restore helper for Paseo built-in Windows notifications (HKCU `Enabled`; never auto-run by install/refresh/check)
- `../browser-extension/` — shared opt-in Chrome/Edge Manifest V3 route adapter

## Architecture

```text
Windows local machine
  notify-listener.ps1 :23118 (public /notify endpoint, token auth)
    -> popup-focus mode: POST to pi-notify-broker.ps1 :23119 (loopback only)
       -> long-lived WinForms process shows popup cards without per-notification startup
    -> broker unavailable/post fails: fallback to pi-notify-popup.ps1 process
    -> optional QQ mirror: pi-notify-qq-sender.ps1 starts the existing local sender with a temp text file
  pi-notify-reverse-tunnel.ps1
        ^
        | persistent ssh -R reverse tunnel
        |
Remote host my
  Pi extension POST http://127.0.0.1:23118/notify

Optional Pi Web exact route
  notify-listener -> PiNotifyRouteHost current-user named pipe
    -> PiWebDesktop adapter
    -> Chrome/Edge adapter through Native Messaging (only after explicit load/config)
```

The broker binds only `127.0.0.1` and is never exposed through the SSH tunnel. The listener remains the single public entry point and continues to authenticate every request. Route Host does not replace Terminal matching: `originKind=terminal` keeps the existing canonical-title path, while a declared `originKind=pi-web` is either exact or a fail-closed no-op.

`originKind=paseo` is a third, fully isolated branch. Legitimate Paseo payloads display without Terminal `cwdBase/tabTitle`, use a fixed UI label `Paseo`, and store only an opaque DPAPI-protected activation handle. Click paths (broker, fallback popup, system toast, activate-oldest) all call the same Paseo handler and **never** fall through to Terminal or Pi Web. Activation uses loopback CDP only to dispatch Paseo's existing `paseo:web-notification-click` renderer event (no `Page.navigate`, no handcrafted `paseo://` URLs, no cold-start/kill/restart).



## Paseo desktop notifications (opt-in)

### Payload contract

```json
{
  "originKind": "paseo",
  "notificationId": "<uuid>",
  "notificationKind": "finished|permission",
  "title": "<minimal display title>",
  "body": "<minimal display body>",
  "paseoRoute": {
    "version": 1,
    "serverId": "<opaque>",
    "workspaceId": "<opaque>",
    "agentId": "<opaque>"
  }
}
```

Rules:

- `error` and invalid/incomplete routes never create a Paseo desktop popup and never enter Terminal/Pi Web routing.
- Route IDs are for activation only; titles/bodies/cwd are never used to infer the target Agent.
- UI app label is always derived as `Paseo` (not customizable via payload).
- Dedup signatures include origin so identical Pi/Paseo text cannot cross-suppress.
- Same `serverId + agentId` replaces the previous card; different Agents stack. `workspaceId` is kept only inside the protected activation state.

### Privacy

Logs, command lines, temp files, and activation caches must never contain:

- raw title/body
- raw route triple (`serverId`/`workspaceId`/`agentId`)
- tokens / credentials
- CDP WebSocket URLs or page content

Only irreversible fingerprints, fixed result codes, candidate counts, and elapsed times are logged. Click URIs and toast caches carry opaque activation IDs only.

### Authenticated health capability

Unauthenticated `GET /health` remains listener liveness only (`{"ok":true}`).

Sender capability probe is token-protected:

```http
POST /paseo/health
X-Pi-Notify-Token: <token>
```

Fixed JSON schema v1 (no token/paths/ports/PID/target URL/route IDs/title/body):

```json
{
  "version": 1,
  "ready": true,
  "listenerReady": true,
  "displayReady": true,
  "routeReady": true,
  "routeState": "app-absent|ready|disabled|non-loopback|foreign-owner|...",
  "capabilities": {
    "notifyV1": true,
    "closeV1": true,
    "existingClickEventV1": true
  }
}
```

- `ready = listenerReady && displayReady && routeReady`
- popup-focus: display is ready when the owned fallback popup script exists (broker may be down)
- system-toast: display remains ready
- route readiness requires routing enabled, safe high non-conflicting CDP port, controller file + standard Paseo executable, and persisted user `PASEO_ELECTRON_FLAGS` for exact port + `127.0.0.1`
- no CDP listener/Paseo process => `routeReady=true` with `routeState=app-absent`
- listener present => require exact loopback Paseo owner and at least one trusted top-level page
- non-loopback/foreign/ambiguous/malformed/disabled/config mismatch fail closed (`ready=false`)
- health helper is side-effect free (no launch/kill/restart/navigate/env mutation)

### Exact idempotent permission close

```http
POST /paseo/close
X-Pi-Notify-Token: <token>
Content-Type: application/json

{"originKind":"paseo","version":1,"notificationId":"<uuid>"}
```

Responses (HTTP 200 body):

- `ok` — valid idempotent close, including already-missing
- `invalid` — malformed body/origin/version/uuid or unexpected route fields
- `retry` — internal close orchestration failure only

Rules:

- `notificationId` is event-stable across sender retries and is propagated through Show-Toast/broker/fallback/toast (opaque; never enables Terminal/Pi Web fallback)
- close matches only `originKind=paseo + notificationId`; an older resolved permission never closes a newer same-agent popup with another UUID
- bounded 30-minute close tombstone keyed by `SHA-256(notificationId)` only (no plaintext ID); listener checks before display and returns `dedup`; max 96 markers with atomic/serialized cleanup
- close revokes matching DPAPI activation entries and invalidates later clicks (bounded scan; fingerprint logs only)
- broker closes matching card(s) on the UI thread by origin+notification UUID
- fallback popup self-closes via Local named event derived from full SHA-256 plus tombstone polling (no process kill)
- system toast: Tag = notification UUID, Group = agent fingerprint; remove prior same-agent group before show; exact tag+group on close; toast-history errors are best-effort and must not block broker/fallback/cache close

### Child sender integration notes

- `dedup` is terminal delivery (do not retry as if transient)
- health uses the authenticated **POST** `/paseo/health` contract (not unauthenticated GET `/health`)
- close valid/missing is idempotent `ok`

### Foreground suppression

Listener returns `suppressed-active-agent` only when a trusted Paseo page is **visible, focused, and showing the same `serverId + agentId`**. Minimized, background, multi-window ambiguity, CDP down, or unknown state default to **show**. `finished` suppressed as known; `permission` retention/re-show is sender-side.

### Click activation and retry

- Activation state lives under the instance runtime dir in `paseo-activation/` with CurrentUser DPAPI fields.
- TTL = `min(popupTimeoutSeconds, 1800)`.
- Read does not consume; only successful exact-agent acceptance consumes. Temporary failures release the in-flight lease and restore a retry UI (“跳转失败，点击重试”). Permanent failures (`expired`/`invalid`/`ambiguous`/`foreign-owner`/`non-loopback`) disable the card without Terminal fallback.

### Enable / disable (deployment gate)

Routing defaults to **disabled** (`paseoDesktopRoutingEnabled=false`, CDP port `29318`). Install/refresh/restart copy `paseo-desktop-route.ps1` and `set-paseo-desktop-routing.ps1` into the runtime bin but **never execute** the helper.

```powershell
# Explicit, interactive, user-level only. Does not kill/restart Paseo.
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-paseo-desktop-routing.ps1 -Enable
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-paseo-desktop-routing.ps1 -Disable
```

Enable persists user-level `PASEO_ELECTRON_FLAGS` with loopback-only remote debugging flags, saves a backup of the previous flags, and requires a **manual Paseo restart**. Notification clicks never set environment variables. Disable restores the backup and turns the config flag off.

### Final controlled takeover (built-in notifications)

After Linux sender live delivery, exact click routing, and Pi/Codex/Grok Build probes are confirmed, disable Paseo built-in Windows notifications with the **manual** helper only. Install, refresh, restart, and check copy the helper but **never execute** `-Disable` or `-Restore`.

```powershell
# Explicit interactive takeover. Writes HKCU Enabled=0 for electron.app.Paseo.
# First Disable atomically saves original presence/value under:
#   %USERPROFILE%\.pi-notify\paseo-built-in-notification-state.json
# Repeated Disable is idempotent and never overwrites the original backup with 0.
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-paseo-built-in-notifications.ps1 -Disable

# One-shot restore from the saved backup (deletes backup after success).
# If the property was originally absent, Restore removes Enabled.
# Missing backup fails closed and does not modify the registry.
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-paseo-built-in-notifications.ps1 -Restore
```

Recommended takeover order (all manual):

1. Keep sender `deliveryMode=live` and Windows bridge healthy.
2. Enable Pi lease gate only after explicit confirmation (`paseoLeaseGateEnabled` / `PI_NOTIFY_PASEO_LEASE_GATE=1`).
3. Run `set-paseo-built-in-notifications.ps1 -Disable`.
4. Observe for 24 hours; keep `PI_NOTIFY_ALLOW_PASEO=1` as emergency Pi fallback.

One-shot rollback:

1. `set-paseo-built-in-notifications.ps1 -Restore`
2. Disable Pi lease gate / set `PI_NOTIFY_ALLOW_PASEO=1` if needed
3. Stop or shadow the Linux sender if required
4. `set-paseo-desktop-routing.ps1 -Disable` if CDP routing must also roll back

### Security residual risk and rollback

CDP has no authentication; any same-user local process that can reach the loopback port can control the page. Keep routing disabled until Windows live verification confirms loopback binding, owner checks, multi-window fail-closed behavior, and privacy. On any safety failure: keep/disable routing, run desktop-routing `-Disable`, restore built-in notifications with `set-paseo-built-in-notifications.ps1 -Restore`, and do not kill Paseo.


## First-time remote install

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-remote-windows-notify.ps1 -RemoteHostAlias my
```

This creates/updates:

- local config: `%USERPROFILE%\.pi-notify\config.json`
- remote extension: the installed package entry, or `~/.pi/agent/extensions/remote-windows-notify.ts` only when the package is absent
- remote config: `~/.pi/agent/remote-windows-notify.json`

If the package is installed, an identical legacy global extension is removed to prevent duplicate Pi
hook registration. A different global file is treated as a conflict and the installer stops without
overwriting it.

## Manual mode

Start the listener:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\pi-notify-restart-listener.ps1
```

Start the reverse tunnel:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\pi-notify-reverse-tunnel.ps1
```

Or ad-hoc SSH:

```powershell
ssh -R 127.0.0.1:23118:127.0.0.1:23118 my
```

## One-shot autostart install

### Windows + Linux together

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-autostart-all.ps1 -RemoteHostAlias my
# custom remote Pi dir:
# powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-autostart-all.ps1 -RemoteHostAlias my -RemotePiDir /custom/pi/agent
```

### Windows only

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-windows-autostart.ps1 -RemoteHostAlias my
```

Installer behavior:

- removes legacy scheduled tasks named `PiNotifyListener`, `PiNotifyTunnel`, and `PiNotifyWatchdog`
- writes Startup-folder launchers for listener/broker/tunnel/watchdog
- writes a Startup-folder `PiNotifyHotkey.vbs` launcher for the resident configured `popupHotkey`

Startup files:

- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyListener.vbs`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyBroker.vbs`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyTunnel.vbs`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyWatchdog.vbs`

Hotkey launcher:

- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyHotkey.vbs`

They start at user logon. `PiNotifyListener.vbs` invokes `pi-notify-restart-listener.ps1`, so startup keeps the runner-owned listener invariant instead of launching `notify-listener.ps1` directly. `PiNotifyBroker.vbs` launches the long-lived WinForms broker with `-STA` so popup cards appear without per-notification PowerShell startup. `PiNotifyTunnel` keeps retrying automatically if SSH drops, and `PiNotifyWatchdog` periodically verifies local listener, broker, and remote loopback tunnel health and restarts the broken side when needed. The resident `PiNotifyHotkey.vbs` worker owns the global popup hotkey, so single-modifier shortcuts and single-modifier shortcuts such as `Alt+L` work reliably without depending on Explorer shortcut-hotkey registration.

## Refresh after pull

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\pi-notify-refresh.ps1
```

By default this sets `popup-focus`, `popupPlacement=cursor`, and a 1800 second (30 minute) timeout, syncs Windows runtime files, restarts the listener, and restarts the reverse tunnel. Add `-Pull` to run a fast-forward-only git pull. Add `-SyncRemote` to sync the remote `my` extension/config and update any existing Pi package-cache extension copies. When using a non-default remote Pi directory, pass `-RemotePiDir` together with `-SyncRemote` so refresh updates the same directory that autostart installed. Use `-SkipRemoteSync` only when the remote host is unavailable and you know the remote config is already current.

Run the fixed-root check script when validating from another working directory:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\pi-notify-check.ps1
```

### Linux `my` only

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-linux-autostart.ps1 -RemoteHostAlias my
# custom remote Pi dir:
# powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-linux-autostart.ps1 -RemoteHostAlias my -RemotePiDir /custom/pi/agent
```

Installs and enables a user-level autostart guard:

- preferred: `systemd --user` service `pi-remote-windows-notify-ensure.service`
- fallback: user `crontab @reboot` entry when `systemd --user` is unavailable

It runs on Linux user startup and calls the same atomic ensure program used during install. The saved
install state restores the selected `-RemotePiDir`, keeps package and standalone modes mutually
exclusive, and verifies the remote config remains mode `0600`. The default remote Pi directory is
`~/.pi/agent/`.

## After autostart is installed

You no longer need to manually add `-R` to your interactive `wt ssh my` command.

The background tunnel task on Windows already keeps `my:127.0.0.1:23118` forwarded back to your Windows machine.

## If Pi is already open on `my`

Run in Pi:

```text
/reload
```

## Manual bridge test

From `my`:

```bash
curl -X POST http://127.0.0.1:23118/notify \
  -H 'Content-Type: application/json' \
  -H 'X-Pi-Notify-Token: <token-from-local-config>' \
  -d '{"title":"Pi","body":"Hello from remote my","focusTarget":"my","cwdBase":"manual-test","tabTitle":"manual-test"}'
```

Expected result:

- Windows shows a toast or popup card
- response body is `ok`

When `displayMode` is `popup-focus`, Terminal notifications must include `cwdBase` or `tabTitle`; metadata-free Terminal payloads are intentionally dropped as `no-target` so clicks never jump to the wrong terminal. Paseo (`originKind=paseo`) is exempt from that gate and still displays without Terminal metadata.

## Config

Local config path:

- `%USERPROFILE%\.pi-notify\config.json`

If you pass `-ConfigPath C:\path\to\config.json`, that file's parent directory is the isolated instance base. The instance's `bin\`, `logs\`, `listener.pid`, `tunnel.pid`, and `watchdog.pid` stay under that parent instead of `%USERPROFILE%\.pi-notify`.

Important keys:

```json
{
  "listenHost": "127.0.0.1",
  "port": 23118,
  "remoteHostAlias": "my",
  "sshExecutable": "C:/.../ssh.exe",
  "tunnelRetryDelaySeconds": 5,
  "tunnelStartupDelaySeconds": 15,
  "displayMode": "system-toast",
  "popupTimeoutSeconds": 1800,
  "popupWallpaperPath": "C:/Users/Administrator/.pi-notify/bin/popup-wallpaper.png",
  "popupPlacement": "cursor",
  "popupHotkey": "Alt+L",
  "popupHotkeyEnabled": true,
  "brokerEnabled": true,
  "brokerPort": 23119,
  "brokerStartupTimeoutMs": 700,
  "brokerRequestTimeoutMs": 700,
  "qqNotifyEnabled": false,
  "qqNodeExecutable": "node.exe",
  "qqSenderScript": "",
  "qqSendTimeoutSeconds": 20,
  "qqMaxConcurrent": 2,
  "token": "..."
}
```

`tunnelStartupDelaySeconds` is normalized to at least 5 seconds to avoid startup races between listener, tunnel, and watchdog.

QQ mirror keys are non-sensitive and default to disabled. Keep QQ account, recipient, token, secret, and OpenClaw configuration outside this bridge config.

Broker keys (auto-upgraded with safe defaults when missing):

- `brokerEnabled` (default `true`) — when `true`, `popup-focus` mode prefers the long-lived broker; when `false`, the listener uses the old per-notification `pi-notify-popup.ps1` process path.
- `brokerPort` (default `23119`) — loopback-only HTTP port for the broker. The broker binds only `127.0.0.1` and is never exposed through the SSH tunnel.
- `brokerStartupTimeoutMs` (default `700`) — bounded wait when the listener starts the broker on first use.
- `brokerRequestTimeoutMs` (default `700`) — bounded timeout for listener-to-broker `/popup` posts; on failure the listener falls back to the popup process path.

QQ mirror keys (auto-upgraded with safe defaults when missing):

- `qqNotifyEnabled` (default `false`) — opt-in only. Install, refresh, and restart keep it disabled unless you explicitly set it.
- `qqNodeExecutable` (default `node.exe`) — Node executable name or path used by the local worker.
- `qqSenderScript` (default empty) — path to the existing local QQ sender script, for example the Jira Watch sender that accepts `--text-file`.
- `qqSendTimeoutSeconds` (default `20`, capped at `120`) — one-shot sender timeout. Timeout kills the direct Node child and does not retry.
- `qqMaxConcurrent` (default `2`, capped at `8`) — maximum live QQ workers. When the limit is reached the QQ branch is dropped, not queued.

QQ delivery runs only after token authentication, display text normalization, target validation, the existing five-second dedupe gate, and desktop notification dispatch. This includes `originKind=paseo` after a successful desktop popup (same title/body as the card). `no-target`, `dedup`, and `suppressed-active-agent` responses do not start QQ. The QQ text is built only from the final title and body, stored in `%USERPROFILE%\.pi-notify\qq-pending` or the current instance `qq-pending` directory, and passed as a UTF-8 temp file; route keys, session IDs, window handles, tokens, account IDs, and receiver IDs are not included.

Before enabling real QQ sends, validate with a fake sender or the existing sender's `--dry-run`, then get explicit approval for a real smoke because it will notify the configured recipient. Structured evidence is written to `logs\listener.log` and `logs\qq-sender.log` as statuses such as `qq-send-ok`, `qq-send-failed exitCode=<n>`, `qq-send-timeout`, `qq-send-unavailable reason=<kind>`, or `qq-send-drop reason=capacity`; logs must not contain message text, sender stdout/stderr, account/recipient identifiers, or credentials. To roll back QQ only, set `qqNotifyEnabled` to `false` and restart the listener; desktop notifications do not require code rollback.

Remote config also supports:

```json
{
  "messageMode": "dynamic",
  "title": "Pi",
  "bodyTemplate": "host: {host} | cwd: {cwdBase}",
  "remoteHostAlias": "my",
  "originKind": "pi-web",
  "instanceKey": "11111111-2222-3333-4444-555555555555"
}
```

Only set `originKind=pi-web` for the Pi Web service instance. `instanceKey` is an opaque instance identifier shared with the trusted Windows adapters; do not reuse it for a different Pi Web data root/service. TUI sessions remain `terminal` even when the same config file contains the Pi Web fields.

Notification payloads may include:

```json
{
  "focusTarget": "my",
  "cwdBase": "project-name",
  "tabTitle": "π - session-name - project-name · #12hex-session-key",
  "sessionName": "human-readable session name"
}
```

Current senders derive the 12-hex session key from a SHA-256 digest of Pi's session ID; the raw session ID is never sent or displayed. The same canonical title is used by the notification payload and the terminal-title spinner, whose activity frame is only a prefix.

When `tabTitle` is present, `popup-focus` requires that complete title and never downgrades the match to `cwdBase`. `cwdBase` is only a compatibility path for older payloads that omit `tabTitle`. It never opens a new Windows Terminal tab/window as a fallback. The custom popup renders `sessionName` as a large accent-colored line above the prompt/body; if no explicit session name is available, it falls back to the tab title/project name.

`popupPlacement` controls which monitor gets the popup card:

- `cursor` -> the screen currently containing the mouse pointer
- `right` -> the right-most screen
- `primary` -> the Windows primary screen

`popupHotkey` defaults to `Alt+L` and is registered by the resident `PiNotifyHotkey.vbs` startup worker, not a Start Menu shortcut. When multiple custom popup cards are visible, pressing it activates the oldest live popup's target tab and only dismisses that selected popup. Press it again to move through the remaining popups in age order. Set `popupHotkeyEnabled` to `false` to disable the global hotkey. `Ctrl+{`, `Alt+P`, `Ctrl+P`, function keys, and common OEM punctuation keys also work as config values; avoid `Ctrl+P` because it conflicts with print shortcuts.

After a popup click or `Alt+L` activates its exact Windows Terminal tab, the bridge also returns that tab's scrollback viewport to the latest output when Windows Terminal exposes a writable UIAutomation scrollbar.

Template fields:

- `{host}` → remote hostname
- `{cwd}` → full current working directory
- `{cwdBase}` → current directory basename

The default popup background is bundled as `popup-wallpaper.png` and copied into `%USERPROFILE%\.pi-notify\bin` by install/refresh.

Default behavior is `messageMode: dynamic`: a validated `rpiv-ask-user-question` prompt shows its first header while waiting, and turn-complete notifications use the last prompt, tool names, and final reply. Static mode never includes ask-user question content; it uses a fixed waiting message plus `bodyTemplate` context.

Loopback HTTP/HTTPS endpoints are allowed. Non-loopback HTTP is rejected. A non-loopback HTTPS
endpoint requires `PI_NOTIFY_ALLOW_NONLOCAL=1`; dynamic prompt/reply content additionally requires
`PI_NOTIFY_ALLOW_NONLOCAL_DYNAMIC=1`, otherwise the extension forces static mode.

Display modes:

- `system-toast` → Windows native toast; clicking the toast tries the same safe tab activation path, but it is best for pure reminder mode
- `popup-focus` → custom no-activate popup card; it does not steal keyboard focus, `x` only closes, clicking the card jumps to the matching Windows Terminal tab. If you manually switch to the target tab first, the popup auto-closes. Popups from different tabs stack upward from the bottom-right; a newer popup from the same tab replaces the older one.

`popup-focus` matching rules:

1. Require the full canonical `tabTitle` from current senders (`π - <sessionName> - <cwdBase> · #<sessionKey>` when named, otherwise `π - <cwdBase> · #<sessionKey>`). A spinner frame before that title is allowed.
2. Use `cwdBase` only when an older sender does not provide `tabTitle`.
3. Activate only when exactly one candidate matches. Multiple title or cwd matches log an `ambiguous` diagnostic and do nothing; enumeration order and the currently selected tab are never tie-breakers.
4. Cache only session-tagged titles and revalidate the live UIAutomation tab name before reuse.
5. If no unique matching tab is found, log `popup-focus-miss` and do nothing. It does **not** open a new tab/window and does **not** jump to `Windows PowerShell`.

Switch modes:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\set-notify-mode.ps1 -Mode system-toast
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\set-notify-mode.ps1 -Mode popup-focus -PopupPlacement cursor
```

## Optional Pi Web exact routing

Exact routing is additive. A Pi Web notification freezes the unique live owner at receive time; clicking later revalidates that same owner and reports `session-url-confirmed`. Zero owners, multiple owners, stale pages, an unavailable adapter/Route Host, malformed metadata, or a failed foreground operation are no-ops. They never fall back to Terminal scanning, browser-title matching, a recent window, or a new tab.

### Build and install Route Host

```powershell
cd .\windows\route-host
dotnet test .\PiNotifyRouteHost.sln -c Release
dotnet publish .\src\PiNotifyRouteHost\PiNotifyRouteHost.csproj `
  -c Release -r win-x64 --self-contained true -o .\publish
.\install.ps1 -PublishDir .\publish -ExtensionId jfjmmpbnenmophffljembfmkpppohocj
```

The installer writes only current-user locations: `%LOCALAPPDATA%\PiNotifyRouteHost`, the HKCU Chrome/Edge Native Messaging host keys, and the HKCU `Run\PiNotifyRouteHost` launcher. Rerun the same publish/install commands to upgrade. Back up the prior install directory before replacement when rollback evidence is required.

### PiWebDesktop adapter

Use the tracked source under `tools\pi-web-desktop`; do not retain only a hand-copied executable. Put the same `instanceKey` in `%LOCALAPPDATA%\PiWebDesktop\route-config.json`, build, verify, then replace the installed executable from the verified `output\PiWebDesktop-win-x64` artifact:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
powershell -ExecutionPolicy Bypass -File .\verify.ps1
```

The desktop app registers only after a successful trusted-origin WebView2 navigation containing `?session=`. It heartbeats its adapter/owner lease and uses the existing window restore/focus path; it does not navigate notifications to an arbitrary URL or create a second window.

After `route-config.json` exists, `install-remote-windows-notify.ps1` reads its validated `instanceKey` and projects `originKind=pi-web` plus the same key into the managed Linux notification config. `pi-notify-refresh.ps1 -SyncRemote` uses that installer. Restart or reload the Pi Web host after synchronization so new session runtimes consume the updated config. `pi-notify-check.ps1` compares only the key fingerprints and fails when the Windows route authority and managed Linux config drift; it never prints the raw key.

A test that posts an already-frozen popup directly to the broker verifies click activation only. It does not prove that a real Pi Web session emitted exact-route metadata. End-to-end acceptance additionally requires a newly created Pi Web session notification to produce `notify-received originKind=pi-web`, a ready/recovering freeze, and a final handled click without Terminal fallback.

### Chrome and Edge adapters

```bash
cd browser-extension
npm test
npm run build
```

Loading is deliberately manual: open `chrome://extensions` or `edge://extensions`, enable Developer mode, load the corresponding `build/<browser>` directory, then configure the trusted Pi Web origin and matching `instanceKey` in extension options. Native-host registry keys alone do not install or activate an extension. Validate Chrome and Edge separately; do not claim either browser supported until its unpacked extension has been loaded and the end-to-end unique/ambiguous/stale matrix has passed.

### Verify and recover

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\test-route.ps1
powershell -ExecutionPolicy Bypass -File .\windows\pi-notify-check.ps1
powershell -ExecutionPolicy Bypass -File .\windows\route-host\install.ps1 `
  -PublishDir .\windows\route-host\publish -ExtensionId jfjmmpbnenmophffljembfmkpppohocj
```

Useful structured evidence is in `%USERPROFILE%\.pi-notify\logs\listener.log`, `broker.log`, and the Route Host daemon stdout/stderr files under `%LOCALAPPDATA%\PiNotifyRouteHost`. PiWebDesktop emits route diagnostics only through its debug listener; the final adapter acknowledgement is recorded by the broker. Logs contain only fingerprints/reasons, not raw session IDs, full Pi Web URLs, tokens, or routing keys.

Recovery order: confirm Route Host is running, confirm the Desktop/browser adapter is connected, confirm the page URL still has the intended `?session=`, then generate a new notification. Route Host restart invalidates old snapshots by design; it must not resurrect stale tab/window handles. If a notification froze as `miss` or `ambiguous`, opening/closing a page later does not retarget that old notification.

### Disable or uninstall

For a reversible disable, set the Desktop `route-config.json` `enabled` field to `false`, unload the browser extension, and leave `originKind=pi-web` configured; Pi Web notification clicks then remain fail-closed.

To remove Route Host after backing up the install directory:

```powershell
Stop-Process -Name PiNotifyRouteHost -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\io.pi.notify.route' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\io.pi.notify.route' -Recurse -Force -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name PiNotifyRouteHost -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\PiNotifyRouteHost" -Recurse -Force
```

Do not delete browser profile data, Pi session files, or PiWebDesktop WebView data as part of route removal.

## Troubleshooting

### Broker health

Check the broker is alive on loopback:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:23119/health -TimeoutSec 3
```

If the broker is unavailable, the listener automatically falls back to the per-notification `pi-notify-popup.ps1` process path, so notifications are not lost. The watchdog restarts the broker when it is missing or unhealthy.

To disable the broker and restore the old per-notification behavior, set `brokerEnabled` to `false` in the config and refresh:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\pi-notify-refresh.ps1 -SkipTunnel -SkipRemoteSync
```

### No toast shown

1. check `PiNotifyListener` / `PiNotifyTunnel` scheduled tasks if task mode was used
2. otherwise check the Startup-folder `PiNotify*.vbs` files still exist
3. run the manual `curl` test from `my`
4. if Pi was already running before install, run `/reload`

### Token mismatch

Check both files use the same token:

- local: `%USERPROFILE%\.pi-notify\config.json`
- remote: `~/.pi/agent/remote-windows-notify.json`

### Change the port

Re-run the installers with a custom port:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-autostart-all.ps1 -RemoteHostAlias my -Port 23118
```
