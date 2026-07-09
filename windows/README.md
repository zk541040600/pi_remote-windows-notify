# Remote Pi → Windows Notify Bridge

This folder implements a reliable **Windows local notification bridge** for running Pi on remote host `my` while still receiving desktop notifications on Windows.

## Files

- `NotifyBridge.Common.ps1` — shared config / path / SSH helpers
- `notify-listener.ps1` — Windows local HTTP listener that shows toast notifications
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

## Architecture

```text
Windows local machine
  notify-listener.ps1 :23118 (public /notify endpoint, token auth)
    -> popup-focus mode: POST to pi-notify-broker.ps1 :23119 (loopback only)
       -> long-lived WinForms process shows popup cards without per-notification startup
    -> broker unavailable/post fails: fallback to pi-notify-popup.ps1 process
  pi-notify-reverse-tunnel.ps1
        ^
        | persistent ssh -R reverse tunnel
        |
Remote host my
  Pi extension POST http://127.0.0.1:23118/notify
```

The broker binds only `127.0.0.1` and is never exposed through the SSH tunnel. The listener remains the single public entry point and continues to authenticate every request.

## First-time remote install

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\install-remote-windows-notify.ps1 -RemoteHostAlias my
```

This creates/updates:

- local config: `%USERPROFILE%\.pi-notify\config.json`
- remote extension: `~/.pi/agent/extensions/remote-windows-notify.ts`
- remote config: `~/.pi/agent/remote-windows-notify.json`

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

By default this sets `popup-focus`, `popupPlacement=cursor`, and a 300 second timeout, syncs Windows runtime files, restarts the listener, and restarts the reverse tunnel. Add `-Pull` to run a fast-forward-only git pull. Add `-SyncRemote` to sync the remote `my` extension/config and update any existing Pi package-cache extension copies. When using a non-default remote Pi directory, pass `-RemotePiDir` together with `-SyncRemote` so refresh updates the same directory that autostart installed. Use `-SkipRemoteSync` only when the remote host is unavailable and you know the remote config is already current.

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

It runs on Linux user startup and ensures the remote Pi extension/config are restored into `-RemotePiDir` from a managed copy. The default remote Pi directory is `~/.pi/agent/`.

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

When `displayMode` is `popup-focus`, include `cwdBase` or `tabTitle`; metadata-free payloads are intentionally dropped as `no-target` so clicks never jump to the wrong terminal.

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
  "popupTimeoutSeconds": 18,
  "popupWallpaperPath": "C:/Users/Administrator/.pi-notify/bin/popup-wallpaper.png",
  "popupPlacement": "cursor",
  "popupHotkey": "Alt+L",
  "popupHotkeyEnabled": true,
  "brokerEnabled": true,
  "brokerPort": 23119,
  "brokerStartupTimeoutMs": 700,
  "brokerRequestTimeoutMs": 700,
  "token": "..."
}
```

`tunnelStartupDelaySeconds` is normalized to at least 5 seconds to avoid startup races between listener, tunnel, and watchdog.

Broker keys (auto-upgraded with safe defaults when missing):

- `brokerEnabled` (default `true`) — when `true`, `popup-focus` mode prefers the long-lived broker; when `false`, the listener uses the old per-notification `pi-notify-popup.ps1` process path.
- `brokerPort` (default `23119`) — loopback-only HTTP port for the broker. The broker binds only `127.0.0.1` and is never exposed through the SSH tunnel.
- `brokerStartupTimeoutMs` (default `700`) — bounded wait when the listener starts the broker on first use.
- `brokerRequestTimeoutMs` (default `700`) — bounded timeout for listener-to-broker `/popup` posts; on failure the listener falls back to the popup process path.

Remote config also supports:

```json
{
  "messageMode": "dynamic",
  "title": "Pi",
  "bodyTemplate": "host: {host} | cwd: {cwdBase}",
  "remoteHostAlias": "my"
}
```

Notification payloads may include:

```json
{
  "focusTarget": "my",
  "cwdBase": "project-name",
  "tabTitle": "π - session-name - project-name",
  "sessionName": "human-readable session name"
}
```

`popup-focus` uses `tabTitle` first, then `cwdBase`. It never opens a new Windows Terminal tab/window as a fallback. The custom popup renders `sessionName` as a large accent-colored line above the prompt/body; if no explicit session name is available, it falls back to the tab title/project name.

`popupPlacement` controls which monitor gets the popup card:

- `cursor` -> the screen currently containing the mouse pointer
- `right` -> the right-most screen
- `primary` -> the Windows primary screen

`popupHotkey` defaults to `Alt+L` and is registered by the resident `PiNotifyHotkey.vbs` startup worker, not a Start Menu shortcut. When multiple custom popup cards are visible, pressing it activates the oldest live popup's target tab and only dismisses that selected popup. Press it again to move through the remaining popups in age order. Set `popupHotkeyEnabled` to `false` to disable the global hotkey. `Ctrl+{`, `Alt+P`, `Ctrl+P`, function keys, and common OEM punctuation keys also work as config values; avoid `Ctrl+P` because it conflicts with print shortcuts.

Template fields:

- `{host}` → remote hostname
- `{cwd}` → full current working directory
- `{cwdBase}` → current directory basename

The default popup background is bundled as `popup-wallpaper.png` and copied into `%USERPROFILE%\.pi-notify\bin` by install/refresh.

Default behavior is `messageMode: dynamic`: the toast title/body are generated from the last prompt, tool names, and final reply. `bodyTemplate` is used as fallback, or when `messageMode` is set to `static`.

Display modes:

- `system-toast` → Windows native toast; clicking the toast tries the same safe tab activation path, but it is best for pure reminder mode
- `popup-focus` → custom no-activate popup card; it does not steal keyboard focus, `x` only closes, clicking the card jumps to the matching Windows Terminal tab. If you manually switch to the target tab first, the popup auto-closes. Popups from different tabs stack upward from the bottom-right; a newer popup from the same tab replaces the older one.

`popup-focus` matching rules:

1. Prefer exact-ish `tabTitle` from the sender (`π - <sessionName> - <cwdBase>` when the Pi session is named, otherwise `π - <cwdBase>`).
2. Fall back to `cwdBase` when older senders do not provide `tabTitle`.
3. If no matching tab is found, log `popup-focus-miss` and do nothing. It does **not** open a new tab/window and does **not** jump to `Windows PowerShell`.

Switch modes:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\set-notify-mode.ps1 -Mode system-toast
powershell.exe -ExecutionPolicy Bypass -File .\scripts\pi-notify\set-notify-mode.ps1 -Mode popup-focus -PopupPlacement cursor
```

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
