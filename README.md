# Pi Remote Windows Notify

Windows-side files for the Remote Pi → Windows notification bridge.

See [`windows/README.md`](windows/README.md) for installation, autostart, configuration, and troubleshooting instructions.

## Layout

- `linux/` — canonical Pi package entry and example runtime config.
- `windows/` — PowerShell listener, tunnel/watchdog installers, the byte-identical extension template, and the remote ownership ensure program.
- `test/` — config/lifecycle and package-vs-standalone ownership regressions.

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

## Development checks

```bash
npm test
npm run check
```
