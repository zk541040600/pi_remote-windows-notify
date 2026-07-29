# Owner Priority Contract

## Scope

For one `(instanceKey, routingKey)` with both Chrome/Edge and PiWebDesktop live owners,
new notification freezes select the adapter whose session document was most recently
explicitly opened. Existing notification snapshots remain bound to their original
`ownerKey`, `pageKey`, and `adapterKey`.

## Register-owner fields

`register-owner` remains protocol version 1 and adds optional fields:

```json
{
  "ownerEvent": "explicit-open",
  "openEventId": "opaque-idempotency-id",
  "openedAtMs": 1700000000000
}
```

- `ownerEvent=explicit-open` is sent only for a committed/reloaded browser document,
  a WebView navigation completion, or a same-document session change.
- `ownerEvent=restore` is sent for enumeration, heartbeat-related owner refresh,
  transport reconnect, MV3 service-worker recovery, and daemon recovery.
- Legacy callers may omit the fields; omission is treated as an unranked restore.
- An explicit open requires an opaque `openEventId` and bounded Unix-millisecond
  `openedAtMs`. Restore publications must not carry `openedAtMs`.
- No raw session id, URL, token, page content, or notification content is added.

## Persistence and selection

The daemon stores `%LOCALAPPDATA%\PiNotifyRouteHost\route-preferences.json`.
The session dictionary key is SHA-256 of `instanceKey + NUL + routingKey`; values contain
only opaque adapter/event identifiers, timestamps, and monotonically increasing revisions.
Writes use a same-directory temporary file followed by atomic replacement.

For each adapter and route:

1. Replaying the same `openEventId` is idempotent.
2. An older `openedAtMs` cannot overwrite newer adapter metadata.
3. Equal timestamps are ordered by the daemon-assigned persisted revision.
4. Restore/heartbeat/reconnect publications never create or update a rank.
5. A winner may be selected only when every live owner has valid durable metadata; the
   daemon never chooses from a ranked subset.
6. With complete metadata, highest `(openedAtMs, revision)` wins.
7. If metadata is absent/corrupt, or the winning adapter has multiple same-route owners,
   selection returns `ambiguous` and creates no snapshot.
8. A single live owner remains compatible and routes without priority metadata.
9. If an explicit-open rank cannot be persisted, registration is rejected with
   `preference-persist-failed`; the daemon never acknowledges non-durable ordering.

## Validation matrix

| Input/state | Result |
| --- | --- |
| One live owner, no metadata | `ready` |
| Chrome explicit, then Desktop explicit | Desktop `ready` |
| Desktop explicit, then Chrome explicit | Chrome `ready` |
| Winner followed by heartbeat/reconnect/restore | Winner unchanged |
| Daemon restart, owners restore in reverse order | Persisted winner unchanged |
| Equal timestamps, different explicit events | Later persisted revision wins |
| Corrupt/missing state plus two restore owners | `ambiguous` |
| One ranked owner plus one unranked owner | `ambiguous` |
| Explicit-open missing event id/timestamp | `rejected` |
| Explicit-open persistence failure | `rejected/preference-persist-failed` |
| Old snapshot followed by another adapter open | Old snapshot unchanged; new freeze uses new winner |

## Required regression tests

- `OwnerPreferenceRoutingTests` covers both open orders, restore/heartbeat stability,
  daemon-only restart, immutable old snapshots, equal timestamps, corrupt/missing state,
  and state-file leakage.
- Browser `owner-registry.test.mjs` proves enumeration publishes `restore`, committed
  documents publish `explicit-open`, later refreshes return to `restore`, and messages
  contain neither raw session ids nor full URLs.
- PiWebDesktop self-test proves a new document publishes `explicit-open` and an
  acknowledged owner republishes as `restore`.
