# Linux side

This side contains the Pi extension that runs on the remote/Linux machine and notifies Windows when a Pi turn ends or `rpiv-ask-user-question` waits for an answer.

## Files

- `extensions/remote-windows-notify.ts` - Pi extension declared by the repo root `package.json`.
- `remote-windows-notify.example.json` - example runtime config. Copy it to `~/.pi/agent/remote-windows-notify.json` and replace the token.

## Install

Recommended: install the repo as a Pi package.

```bash
pi install git:github.com/zk541040600/pi_remote-windows-notify
cp ~/.pi/agent/git/github.com/zk541040600/pi_remote-windows-notify/linux/remote-windows-notify.example.json \
  ~/.pi/agent/remote-windows-notify.json
```

For local development before pushing, install the local checkout instead:

```bash
pi install /root/work/pi_remote-windows-notify
```

Edit `~/.pi/agent/remote-windows-notify.json`:

- `endpoint` should point to the Windows listener endpoint.
- `token` must match the Windows listener token.

Then restart Pi or run `/reload`.

The package entry is the preferred active source. `pi-notify-ensure.mjs`, used by the Windows
installer and Linux boot guard, keeps exactly one load path: package copies when this package is
installed, otherwise the standalone global extension. A different pre-existing global copy causes
the installer to fail for manual review instead of overwriting it.

## Environment overrides

- `PI_NOTIFY_CONFIG` - config file path.
- `PI_NOTIFY_ENDPOINT` - override endpoint.
- `PI_NOTIFY_TOKEN` - override token.
- `PI_NOTIFY_TIMEOUT_MS` - override timeout, clamped to 1000-15000 ms.
- `PI_NOTIFY_TITLE` - notification title.
- `PI_NOTIFY_BODY_TEMPLATE` - body template, supports `{host}`, `{cwd}`, and `{cwdBase}`.
- `PI_NOTIFY_REMOTE_ALIAS` - Windows listener focus target / remote host alias.
- `PI_NOTIFY_DISABLED=1` - disable notifications.
- `PI_NOTIFY_ALLOW_NONLOCAL=1` - allow a non-loopback HTTPS endpoint. Non-loopback HTTP is always rejected.
- `PI_NOTIFY_ALLOW_NONLOCAL_DYNAMIC=1` - additionally allow prompts/replies in notifications sent to a non-loopback HTTPS endpoint; without this flag they are forced to static mode.

Notification failures are ignored so they never break Pi.
