# Pi Remote Windows Notify

Windows-side files for the Remote Pi → Windows notification bridge.

See [`windows/README.md`](windows/README.md) for installation, autostart, configuration, and troubleshooting instructions.

## Layout

- `windows/` — PowerShell listener, tunnel/watchdog installers, and the `remote-windows-notify.ts` Pi extension template uploaded to the remote host.

## Linux-side Pi package

Install the Pi extension on the remote/Linux machine:

```bash
pi install git:github.com/zk541040600/pi_remote-windows-notify
cp ~/.pi/agent/git/github.com/zk541040600/pi_remote-windows-notify/linux/remote-windows-notify.example.json \
  ~/.pi/agent/remote-windows-notify.json
```

Edit `~/.pi/agent/remote-windows-notify.json` and set the Windows listener token. See `linux/README.md` for details.
