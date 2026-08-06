# paseo-sender

Provider-independent Linux user service that consumes **Paseo unified attention events** and delivers `finished` / `permission` notifications to the existing Windows notify bridge (`originKind=paseo` v1).

## Scope

- Popup trigger: `@getpaseo/client` `DaemonClient.onAgentAttentionRequired`
- Lifecycle only: `agent_permission_request` / `agent_permission_resolved` / `agent_deleted`
- No provider-specific branches (Pi / Codex / Grok Build share one handler)
- Does **not** embed in Pi/Codex/Grok processes
- Does **not** talk to CDP / Windows Terminal routing

## SDK pin

```json
"@getpaseo/client": "0.3.0-beta.2"
```

Direct dependency + committed `package-lock.json`. Do **not** dynamically load the global Paseo CLI nested `node_modules`.

## Modes

| Mode | Behavior |
|------|----------|
| `shadow` (default) | Full normalize/outbox/reconcile; **no** Windows POST |
| `live` | POST `/notify` and `/paseo/close` |

Enable live only after offline verification and explicit config:

```json
{ "deliveryMode": "live" }
```

or `PASEO_SENDER_DELIVERY_MODE=live` / `paseo-sender run --live`.

## Windows parent contracts

### Notify

`POST /notify` + `X-Pi-Notify-Token`:

```json
{
  "originKind": "paseo",
  "notificationId": "<uuid>",
  "notificationKind": "finished|permission",
  "title": "<minimal>",
  "body": "<minimal>",
  "paseoRoute": {
    "version": 1,
    "serverId": "...",
    "workspaceId": "...",
    "agentId": "..."
  }
}
```

Responses: `ok|dedup|suppressed-active-agent|retry|invalid`.

- `ok|dedup` → delivered
- `suppressed-active-agent` → finished terminalized; permission retained + backoff
- `retry` / transport / 5xx → backoff
- `invalid` → terminal contract error

### Health (lease)

Authenticated **only**:

```http
POST /paseo/health
X-Pi-Notify-Token: <token>
```

Schema v1 is exact: `listenerReady/displayReady/routeReady` must be booleans,
`ready` must equal their conjunction, `routeState` must be a known bounded state, and
`capabilities.notifyV1/closeV1/existingClickEventV1` must all be `true`.

Unauthenticated `GET /health` is **not** used.

Lease file `health.json` is refreshed every 5s only in enabled `live` mode after the
store is healthy, initial/reconnect authority reconciliation completed, daemon is
`connected` with `server_info`, and Windows health passes. It is stale after 15s.

### Close

```http
POST /paseo/close
{"originKind":"paseo","version":1,"notificationId":"<uuid>"}
```

No route triple / popup / process IDs. Idempotent `ok` for missing.

## Config example

`~/.config/paseo-sender/config.json` (mode `0600`):

```json
{
  "enabled": true,
  "deliveryMode": "shadow",
  "daemonUrl": "ws://127.0.0.1:8787",
  "clientId": "paseo-sender",
  "daemonPassword": "<from secret owner>",
  "windowsEndpoint": "http://127.0.0.1:23118/notify",
  "windowsToken": "<token>",
  "detailedSummary": false
}
```

Never put secrets on CLI args or systemd `Environment=`.

## State

Default: `$XDG_STATE_HOME/paseo-sender` (dir `0700`):

- `state.json` — generation, watermarks, processed fingerprints, pending authority WAL state, permission correlation
- `outbox.json` — matching generation, per-agent single display item + stable UUID
- `transaction.json` — short-lived same-directory write-ahead transaction; replayed after interrupted writes
- `health.json` — lease only (no route/token)
- `quarantine/` — corrupt/schema/mode isolation (blocks live delivery)

Transactions write and fsync `transaction.json`, then atomically replace both generation-matched artifacts, fsync the directory, and remove the WAL. Persistent files are `0600`; invalid schema, generation, identity, route, UUID, timestamp, count, size, or mode blocks live delivery.

## CLI

```bash
node src/cli.mjs run            # shadow by default
node src/cli.mjs run --live
node src/cli.mjs check
node src/cli.mjs dry-run
node src/cli.mjs status
```

## systemd --user

```bash
node scripts/install.mjs                 # dry-run (default)
node scripts/install.mjs --apply         # write unit/config only
node scripts/install.mjs --apply --enable-now   # explicit enable
node scripts/disable.mjs                 # dry-run
node scripts/disable.mjs --apply
```

No crontab fallback. Real enable requires user confirmation at deployment gate.

## Pi-only lease gate

Pi extension keeps title maintenance always. Opt-in only:

- config `paseoLeaseGateEnabled: true` or `PI_NOTIFY_PASEO_LEASE_GATE=1`
- When gate on + `PASEO_AGENT_ID` + healthy lease + `PI_NOTIFY_ALLOW_PASEO != 1` → suppress legacy Pi popup
- Stale/read/schema/override → Pi fallback
- Codex/Grok never use this gate

## Privacy

Logs: fixed event names, counts, elapsed, irreversible fingerprints only.
Never log: title/body/summary, route triple, token, daemon password, HTTP credentials.

## Rollback

1. Disable Pi lease gate (`paseoLeaseGateEnabled=false` / unset env)
2. `node scripts/disable.mjs --apply`
3. Re-enable Paseo built-in Windows notifications manually (not automatic)

## Tests

```bash
cd linux/paseo-sender && npm test
# from repo root (includes contract drift guard):
npm test
```

## Deployment gate (out of this offline task)

Do **not** auto-enable live delivery, Pi gate, systemd enable-now, or disable Paseo built-in notifications without a second user confirmation after real provider verification.
