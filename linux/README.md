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

### Applying an update in Pi Web

Pi caches extension factories in its long-running process. Updating the package
on disk, refreshing the browser, or creating/resuming a session does not by
itself invalidate that cache. Run Pi's `/reload` from an idle session after the
update. Wait for that session's child agents to finish first: reload tears down
its extension runtime and can stop its child agents.

Reload clears the shared factory cache for subsequently created runtimes; other
already-bound sessions and running children keep their old handlers until they
are individually reloaded or finished. Verify deployment with a newly created
real child agent and the receiver's logs, plus a main-session notification as a
positive control. A fresh-process SDK test alone cannot prove that a running Pi
Web host has picked up the update.

The package entry is the preferred active source. `pi-notify-ensure.mjs`, used by the Windows
installer and Linux boot guard, keeps exactly one load path: package copies when this package is
installed, otherwise the standalone global extension. A different pre-existing global copy causes
the installer to fail for manual review instead of overwriting it.

## Notification scope

Inside a Pi Web host (`PI_WEB_NO_OPEN=1`), only UI-bound RPC/TUI runtimes send
notifications. Headless SDK runtimes (`print`/`json`), including in-process
`pi-subagents` workers, do not send completion or ask-user notifications. This
filter is runtime-local: it does not silence other tabs, depend on agent names,
or disable session persistence. User-created forks remain eligible. Standalone
CLI senders outside Pi Web retain their existing notification behavior.

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
- `PI_NOTIFY_PASEO_LEASE_GATE=1` - legacy-named opt-in that assigns a `PASEO_AGENT_ID`-launched session to Paseo once at session start.
- `PI_NOTIFY_ALLOW_PASEO=1` - choose the Pi sender instead, but only when present before a new/reloaded session starts.

Paseo ownership is session-sticky: a stale/missing sender health lease does not switch the popup to Pi/Pi Web. Notification failures are ignored so they never break Pi.
