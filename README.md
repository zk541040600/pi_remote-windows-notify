# Pi Remote Windows Notify

Windows-side files for the Remote Pi → Windows notification bridge.

See [`windows/README.md`](windows/README.md) for installation, autostart, configuration, and troubleshooting instructions.

## Layout

- `linux/` — canonical Pi package entry and example runtime config.
- `windows/` — PowerShell listener, tunnel/watchdog installers, the byte-identical extension template, and the remote ownership ensure program.
- `windows/route-host/` — current-user .NET exact-route state machine and named-pipe/native-messaging host.
- `browser-extension/` — shared Manifest V3 adapter for Chrome and Edge; it is opt-in and must be explicitly loaded in each browser profile.
- `test/` — config/lifecycle, ask-user prompt, route metadata, and package-vs-standalone ownership regressions.

## Linux-side Pi package

Install the Pi extension on the remote/Linux machine:

```bash
pi install git:github.com/zk541040600/pi_remote-windows-notify
cp ~/.pi/agent/git/github.com/zk541040600/pi_remote-windows-notify/linux/remote-windows-notify.example.json \
  ~/.pi/agent/remote-windows-notify.json
```

Edit `~/.pi/agent/remote-windows-notify.json` and set the Windows listener token. See `linux/README.md` for details.

The package manifest is the active runtime authority. The Windows installer keeps a standalone
`~/.pi/agent/extensions/remote-windows-notify.ts` only when the package is absent; when the package
exists, it updates the package copies and removes an identical legacy global entry so Pi never loads
two registrations.

The sender uses runtime-local lifecycle ownership: multiple Pi Web sessions and resource-only
extension discovery in one Node process cannot cancel another live session's notifications.
Configured Pi Web RPC sessions add opaque exact-route metadata; raw session IDs are never sent.
Windows Terminal keeps its canonical-title route. Pi Web exact failures always fail closed and never
fall back across origins to a Terminal/browser-title guess.

See [`windows/README.md`](windows/README.md#optional-pi-web-exact-routing) for Route Host installation,
verification, recovery, and uninstall guidance. Browser adapters are not active merely because the
Route Host/native-host registry keys exist; Chrome and Edge each require an explicitly loaded and
configured extension.

## Development checks

```bash
npm test
npm run check
```
