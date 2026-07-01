# Remote Pi → Windows Notify Bridge

This folder implements a reliable **Windows local notification bridge** for running Pi on remote host `my` while still receiving desktop notifications on Windows.

## Files

- `NotifyBridge.Common.ps1` — shared config / path / SSH helpers
- `notify-listener.ps1` — Windows local HTTP listener that shows toast notifications
- `pi-notify-reverse-tunnel.ps1` — persistent reverse SSH tunnel with auto-reconnect
- `pi-notify-watchdog.ps1` — self-heal watchdog for listener/tunnel health
- `set-notify-mode.ps1` — switch between `system-toast` and `popup-focus`
- `install-remote-windows-notify.ps1` — installs the remote Pi extension + config
- `install-windows-autostart.ps1` — registers Windows scheduled tasks or Startup-folder launchers for listener/tunnel/watchdog
- `install-linux-autostart.ps1` — installs Linux systemd boot-time remote guard on `my`
- `install-autostart-all.ps1` — one-shot installer for both Windows + Linux autostart
- `remote-windows-notify.ts` — Pi extension template installed on the remote host

## Architecture

```text
Windows local machine
  notify-listener.ps1
  pi-notify-reverse-tunnel.ps1
        ^
        | persistent ssh -R reverse tunnel
        |
Remote host my
  Pi extension POST http://127.0.0.1:23117/notify
```

## First-time remote install

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\install-remote-windows-notify.ps1 -RemoteHostAlias my
```

This creates/updates:

- local config: `%USERPROFILE%\.pi-notify\config.json`
- remote extension: `~/.pi/agent/extensions/remote-windows-notify.ts`
- remote config: `~/.pi/agent/remote-windows-notify.json`

## Manual mode

Start the listener:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\notify-listener.ps1
```

Start the reverse tunnel:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\pi-notify-reverse-tunnel.ps1
```

Or ad-hoc SSH:

```powershell
ssh -R 127.0.0.1:23117:127.0.0.1:23117 my
```

## One-shot autostart install

### Windows + Linux together

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\install-autostart-all.ps1 -RemoteHostAlias my
```

### Windows only

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\install-windows-autostart.ps1 -RemoteHostAlias my
```

Installer behavior:

- first tries Windows Scheduled Tasks
- if task registration is denied, automatically falls back to Startup-folder launchers

Possible scheduled-task names:

- `PiNotifyListener`
- `PiNotifyTunnel`
- `PiNotifyWatchdog`

Fallback Startup files:

- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyListener.vbs`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyTunnel.vbs`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyWatchdog.vbs`

They start at user logon. `PiNotifyTunnel` keeps retrying automatically if SSH drops, and `PiNotifyWatchdog` periodically verifies both local listener health and remote loopback tunnel health and restarts the broken side when needed.

### Linux `my` only

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\install-linux-autostart.ps1 -RemoteHostAlias my
```

Installs and enables:

- systemd service: `pi-remote-windows-notify-ensure.service`

It runs at Linux boot and ensures the remote Pi extension/config are restored into `~/.pi/agent/` from a managed copy.

## After autostart is installed

You no longer need to manually add `-R` to your interactive `wt ssh my` command.

The background tunnel task on Windows already keeps `my:127.0.0.1:23117` forwarded back to your Windows machine.

## If Pi is already open on `my`

Run in Pi:

```text
/reload
```

## Manual bridge test

From `my`:

```bash
curl -X POST http://127.0.0.1:23117/notify \
  -H 'Content-Type: application/json' \
  -H 'X-Pi-Notify-Token: <token-from-local-config>' \
  -d '{"title":"Pi","body":"Hello from remote my"}'
```

Expected result:

- Windows shows a toast
- response body is `ok`

## Config

Local config path:

- `%USERPROFILE%\.pi-notify\config.json`

Important keys:

```json
{
  "listenHost": "127.0.0.1",
  "port": 23117,
  "remoteHostAlias": "my",
  "sshExecutable": "C:/.../ssh.exe",
  "tunnelRetryDelaySeconds": 5,
  "tunnelStartupDelaySeconds": 15,
  "displayMode": "system-toast",
  "popupTimeoutSeconds": 18,
  "token": "..."
}
```

Remote config also supports:

```json
{
  "messageMode": "dynamic",
  "title": "Pi",
  "bodyTemplate": "host: {host} | cwd: {cwdBase}"
}
```

Template fields:

- `{host}` → remote hostname
- `{cwd}` → full current working directory
- `{cwdBase}` → current directory basename

Default behavior is `messageMode: dynamic`: the toast title/body are generated from the last prompt, tool names, and final reply. `bodyTemplate` is used as fallback, or when `messageMode` is set to `static`.

Display modes:

- `system-toast` → Windows native toast, no jump, best for pure reminder mode
- `popup-focus` → custom popup card, click to jump back to the matching WT/tab

Switch modes:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-notify-mode.ps1 -Mode system-toast
powershell.exe -ExecutionPolicy Bypass -File .\windows\set-notify-mode.ps1 -Mode popup-focus
```

## Troubleshooting

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
powershell.exe -ExecutionPolicy Bypass -File .\windows\install-autostart-all.ps1 -RemoteHostAlias my -Port 23118
```
