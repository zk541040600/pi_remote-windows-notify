# PiNotifyRouteHost

Local exact-route hub for Pi Web notification activation (Chrome / Edge / PiWebDesktop).

One executable, three modes:

| Mode | Flag | Role |
|------|------|------|
| Daemon | `--daemon` | Live owner registry, immutable freeze snapshots, named-pipe server |
| Native Messaging relay | `--native` | Browser stdin/stdout framing → daemon pipe |
| One-shot client | `--client --json` | Probe / listener helper |

## Design (external-only)

- Live owners keyed by `(instanceKey, routingKey)`.
- `instanceKey` is exactly 8–128 ASCII letters/digits or `._+-`. Register,
  freeze, and direct-hash boundaries reject every other spelling before route
  state can mutate.
- `routingKey = SHA-256("pi-web-route-v1\\0" + instanceKey + "\\0" + rawSessionId)` (full 256-bit hex).
  `rawSessionId` is strict form-decoded UTF-8 (`+` is space, `%2B` is plus);
  malformed percent/UTF-8 input fails before hashing. Printable edge whitespace
  and valid surrogate pairs are preserved. One 1–256 UTF-16-code-unit contract
  rejects all-portable-whitespace values, C0/C1 controls, U+FEFF, isolated
  surrogates, and `://` at sender, adapter-parser, and direct-hash boundaries.
  An invalid Pi Web sender identity emits terminal-only metadata without
  `instanceKey` or `routingKey`.
- The earliest validated explicit open creates one durable adapter binding per
  `(instanceKey, routingKey)`; later opens/restores cannot steal it. A delayed
  distinct event may correct a provisional later timestamp only within the same
  durable Host receive-clock epoch.
- A live adapter may submit that evidence independently with
  `register-open-intent`. It requires the exact registered generation and
  immutable adapter/browser/profile identity, persists through the normal
  first-binding store, and returns `ok` without creating or changing any live
  owner, page, lease, snapshot, or activation state. Owner capacity is
  therefore not an admission limit for this message.
- Adapter and owner surface identity is a closed tuple:
  `adapterKey + adapterKind + browserKind + profileKey`. Missing fields,
  cross-surface kind combinations, or reuse of one live key with another tuple
  are rejected before leases, owners, or bindings mutate.
- Every adapter-scoped message carries its runtime `adapterGeneration`.
  `register-adapter` also retains one `adapterStartedAtMs`: a durably reserved
  strict order anchored to wall time, not a raw timestamp. Clients persist
  `max(now, prior + 1)` before publication, so equal-millisecond starts and
  clock rollback remain ordered. Retrying the same generation refreshes its
  lease; a newer generation removes the prior owners, pending activation queue,
  and non-terminal work before admission. Delayed old-generation traffic is
  rejected and clients stop trying to reclaim the key. A normal `heartbeat`
  remains lease-only, and the durable first-session binding remains unchanged.
- A material system-clock rollback invalidates all ephemeral adapters, owners,
  snapshots, replay entries, and activations as one clock epoch. Durable
  first-session bindings survive; clients re-register and republish. Retained
  generation/open-event timestamps are not compared with a fresh envelope in a
  way that could strand recovery after rollback.
- Independently of that material-skew runtime reset, every Host request observes
  the durable binding receive clock before replay lookup. Any strict rollback,
  including one millisecond, advances and saves the binding epoch. Events from
  different receive epochs cannot rewrite each other; save failure or epoch
  exhaustion rejects route traffic fail-closed.
- Heartbeat is a proof-bearing lease refresh, never admission. An unknown
  adapter returns `adapter-unavailable/adapter-unknown`; an unknown or
  cross-adapter owner returns `stale/owner-changed`. Clients then reuse their
  ordered registration/owner-publication recovery. Returning `ok` for a missing
  lease is forbidden because it can leave local and daemon registries divergent.
- Chrome/Edge and PiWebDesktop persist an unacknowledged first-open event before
  transport. A worker/app restart may enumerate the page as restore, but a
  matching bounded adapter-scoped outbox republishes the exact original
  `instanceKey/routingKey/openEventId/openedAtMs`; only acknowledgement removes
  it. The instance key is non-secret routing scope; no raw session or URL is
  stored.
- Freeze first filters to the bound adapter: **0 bound owners → miss**,
  **1 → ready(snapshot)**, **2+ within that adapter → ambiguous**. In the
  durable file-store path, one unbound restore owner is
  **miss/owner-unresolved** and 2+ remain **ambiguous** until a real explicit
  open creates a binding.
- Snapshots are **immutable**; later registrations never retarget an old notification.
- Activate revalidates adapter + owner lease + pageKey/fingerprint, then relays command/ack.
- Bounded message size (32 KiB), TTL, nonce/requestId replay cache. Replay
  entries fingerprint the full canonical request: a changed body under the same
  live request ID is rejected, both generic and specialized activate paths
  enforce nonce authority, a nonce collision cannot overwrite the original
  record, and concurrent exact activate calls reserve one side effect.
- Each locked state transition observes wall time once for validation, rollback
  detection, expiry sweep, and mutation; elapsed duration uses a monotonic
  timer.
- Unknown JSON properties are rejected before dispatch. Every local client
  accepts only a protocol-v1 `type=result` frame with the exact request ID.
- Exactly one leading UTF-8 BOM is accepted as a text-transport encoding
  marker, including Windows PowerShell 5.1 `--json -` input. A second BOM or
  U+FEFF inside any identity field remains invalid data.
- A connected daemon pipe must deliver one complete request frame within
  30 seconds, and each response frame has a 5-second total write budget.
  Idle, partial-frame, and non-draining clients are closed, and daemon shutdown
  awaits all accepted handlers instead of leaving detached pipe work.
- **No raw session IDs or full URLs** in logs or persisted snapshot fields.
- A missing binding file means a new writable document. A transient sharing,
  permission, or other I/O failure means the store is unavailable: binding
  reads and writes fail closed and retry the original file on a later route
  operation. It must never synthesize a writable empty document that could
  overwrite valid bindings when the lock clears. Structurally corrupt and
  legacy documents retain the deliberate discard behavior described below.

WT/terminal routing is intentionally **not** handled here.

## Build & test (Windows or SDK host)

```powershell
dotnet test .\PiNotifyRouteHost.sln -c Release
dotnet publish .\src\PiNotifyRouteHost\PiNotifyRouteHost.csproj -c Release -r win-x64 --self-contained false
```

```bash
dotnet test ./PiNotifyRouteHost.sln -c Release
dotnet run --project ./src/PiNotifyRouteHost -- --self-test
```

`--self-test` covers miss/unique/ambiguous/immutable snapshot behavior plus
first-opener binding, bound-adapter offline fail-closed behavior, and restore.
The full test suite additionally covers mandatory persisted surface identity,
corrupt or legacy restore-only state, bounded revision/replay/snapshot
eviction, notification-kind correlation, and in-flight activation protection.

## Install (current Windows user)

Publish first, then install with the deterministic browser-extension id from
`browser-extension/build/<browser>/BUILD_INFO.json`:

```powershell
dotnet publish .\src\PiNotifyRouteHost\PiNotifyRouteHost.csproj `
  -c Release -r win-x64 --self-contained true -o .\publish
.\install.ps1 -PublishDir .\publish -ExtensionId jfjmmpbnenmophffljembfmkpppohocj
```

The installer copies the host under `%LOCALAPPDATA%\PiNotifyRouteHost`, writes the
Native Messaging manifest, registers it for Chrome and Edge under HKCU, configures
a hidden interactive-user logon launcher, starts the daemon, and performs a named-pipe health
check. The default daemon endpoint is `LOCAL\PiNotifyRouteHost`, so Windows
isolates it to the current login session; `CurrentUserOnly` additionally
restricts every pipe instance to the current user. Durable bindings use the
matching session-local path
`%LOCALAPPDATA%\PiNotifyRouteHost\sessions\session-<id>\route-preferences.json`.
On the first upgraded start, exactly one login session publishes a claim marker
under a cross-process lock before copying the legacy user-global binding file.
If the process stops between those steps, only the claimed session may resume
the copy. The source remains available to an old-binary rollback and other
sessions start isolated. The native
relay separately checks the manifest `allowed_origins` list. Registry registration alone does not install a browser
extension; Chrome and Edge remain inactive until the user loads/configures each extension.
During an upgrade, the installer temporarily gates existing Chrome/Edge Native
Messaging registrations, stops only Route Host processes whose executable is
inside this install directory, updates and health-checks the daemon, then
restores the registrations. This prevents an MV3 worker from respawning a relay
that re-locks runtime files during replacement. A Route Host process from a
different executable path makes the upgrade fail closed instead of being
terminated or mistaken for the new daemon.
Installations targeting the same resolved install directory are serialized by
an exclusive `.pi-notify-route-install.lock`. A concurrent installer is
rejected before process, registry, or published-file mutation; the lock handle
and marker are released on both success and failure. The previous publish
ownership index is read only after acquiring that lock, so a process taking
over immediately after another completed install cannot clean with a stale
pre-lock snapshot.
All publish files are staged and hashed before mutation; every managed target
is backed up, copied, and hash-verified. A late failure restores managed files
and the original Chrome/Edge registration values. If the prior daemon was
running, it restarts only after those registrations are restored and only when
the installed files were untouched or fully rolled back. Autostart is committed
after daemon health; obsolete scheduled-task cleanup is best-effort.
The launcher shell-detaches the long-lived daemon so installer/automation
stdout handles close normally instead of making a successful deployment appear
hung.

The publish directory must be flat and separate from the install directory.
Each successful install writes `publish-files.json`; later upgrades remove only
files recorded by that prior index that are absent from the new publish. Runtime
state (`sessions\session-<id>\route-preferences.json`, the one-time legacy
binding file, and daemon logs) and unrelated unknown files are preserved. A
narrow one-time migration removes obsolete versioned
`mscordaccore_amd64_amd64_*.dll` files left by pre-index installations. An
invalid index fails before any published file is replaced. `-SkipRegistration`
is available for isolated files-only verification; it also suppresses daemon
startup.

Rerun publish + install to upgrade. Preserve the previous install directory
before replacement when a rollback is required. Restarting the daemon
intentionally invalidates all old leases and snapshots; adapters must
re-register, and old notifications remain stale rather than retargeting.
Version-4 first-session bindings survive daemon restart and corroborate the
adapter kind/browser/profile with its key. The root persists a Host receive
clock epoch/high-water mark and each binding records its admission epoch.
Exact closed-schema version-3 bindings migrate at legacy epoch 0; the first
version-4 receive durably starts epoch 1, so a post-upgrade earlier timestamp
cannot steal the old binding. Version-1 last-open and version-2 key-only
metadata are discarded on upgrade because they cannot safely reconstruct both
the original opener and its surface identity.

This Host-only rollback barrier has one unavoidable boundary: if Route Host is
offline throughout a rollback and receives a delayed candidate only after wall
time has already caught up past the persisted high-water mark, it cannot infer
that unobserved rollback. Closing that gap would require a trusted monotonic
epoch persisted by the opening surfaces.

To uninstall after taking any required backup:

```powershell
Stop-Process -Name PiNotifyRouteHost -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\io.pi.notify.route' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\io.pi.notify.route' -Recurse -Force -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name PiNotifyRouteHost -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\PiNotifyRouteHost" -Recurse -Force
```

Keep the Linux sender configured as `originKind=pi-web` while an adapter is unavailable if the
desired behavior is fail-closed notification clicks. Do not remove Pi session files or browser/
WebView profile data during Route Host recovery.

## Protocol sketch

Request envelope fields: `protocolVersion`, `type`, `requestId`, `nonce?`, `issuedAtMs`, `expiresAtMs`, plus type-specific opaque keys (`adapterKey`, `ownerKey`, `pageKey`, `instanceKey`, `routingKey`, `notificationId`, `snapshotId`, `activationRequestId`, …).

Important types: `register-adapter`, `register-open-intent`, `register-owner`,
`unregister-owner`, `heartbeat`, `freeze`, `activate`, `poll-activation`,
`activate-progress`, `activate-result`, `activation-status`, `health`.

Adapter-scoped requests also carry `adapterGeneration`;
`register-adapter` carries `adapterStartedAtMs`, and `register-owner` may carry
`replacesOwnerKey` for same-generation atomic predecessor removal.
`register-open-intent` carries only the envelope plus exact adapter identity,
`instanceKey`, `routingKey`, `openEventId`, and positive `openedAtMs`.
Owner/page/lease/notification/snapshot/activation/result fields and
`adapterStartedAtMs` are invalid. Its durable event timestamp is ordered by the
binding store and is not compared with the fresh transport envelope for age or
future skew.

Results: `ready`, `miss`, `ambiguous`, `stale`, `adapter-unavailable`, `accepted`, `pending`, `session-url-confirmed`, `timeout`, `replay`, `expired`, `rejected`, …

### External adapter activation (polling)

Browser extensions register owners over Native Messaging but cannot receive duplex push from the daemon. Exact activation uses a minimal poll protocol:

1. Listener/broker `activate` → daemon validates snapshot and **enqueues** one
   bounded command for the frozen `adapterKey`. Because selection and queue
   commit are separate transactions, commit re-resolves and requires the exact
   same live snapshot/adapter generation; a close or takeover in between is
   stale and consumes no capacity. Immediate result: `accepted` +
   `activationRequestId` (equals activate `requestId`).
2. Extension `poll-activation` with its `adapterKey` → receives the immutable
   command (`result=ready` + owner/page/routing fields), or `ok`/`no-pending`.
   Delivery is leased: an immediate repeat poll is empty, but a lost poll
   response re-offers the same command after 1 second until a terminal result
   or deadline. If the retained clock epoch moves backward within the allowed
   skew, the exact command is re-offered immediately and its delivery lease
   restarts rather than waiting for wall time to catch up.
3. After PiWebDesktop focuses the exact terminal row, it may send one
   non-terminal `activate-progress` with
   `activationPhase=desktop-row-focused-awaiting-proof`. The Host accepts it
   only after delivery and only with the exact adapter generation,
   notification, snapshot, and supplied route correlation. It records the
   phase and first Host observation time but does not dequeue or complete the
   activation, mutate the frozen snapshot/binding/deadline/delivery lease, or
   treat focus as foreground proof. Browser adapters cannot send this phase.
4. Extension/Desktop re-reads the live target and sends `activate-result`
   with `activationRequestId` + terminal result
   (`session-url-confirmed` / `stale` / …). It waits for the daemon response;
   a lost acknowledgement retries the same request ID/nonce envelope before
   another poll. If that transport envelope expires or becomes future-dated
   after clock rollback, only request ID/nonce/times are renewed; correlation
   and terminal outcome remain unchanged.
   The client removes its durable result only after a Host-final response names
   the exact `activationRequestId`, or reports
   `stale/activation-unknown` after daemon state loss; control outcomes and
   unrelated/generic rejection are not acknowledgements.
5. Caller `activation-status` with `activationRequestId` returns `pending` and
   the recorded phase, if any, until terminal, then the final result without a
   phase (TTL-bounded, idempotent).

`--client --json … --wait-ms <ms>` (activate only) polls `activation-status`
internally until terminal or deadline — suitable for PowerShell exact-ack
without a script-side loop. The absolute protocol deadline caps the budget
once; subsequent polling, cancellation, and remaining-time decisions use a
monotonic timer. The same budget begins before pipe connection and covers the
initial activate send plus every poll, so neither a slow pipe nor a wall-clock
rollback can extend the requested wait.
Terminal completion remains the default. Explicit `--return-on-progress`
(valid only once, together with activate `--wait-ms`) may instead return early
only for the exact allowlisted phase; an ordinary `pending` response is not an
early-success condition.
When present, `--wait-ms` must occur once with an invariant decimal integer in
the inclusive range `1..MaxActivationExecutionMs` (`60000`), and the request
type must be `activate`. This execution cap is independent of the ordinary
request-envelope TTL cap (`MaxRequestTtlMs`, `30000`); a longer wait never
widens the freshness of a transport envelope.
Missing, duplicate, malformed, zero, negative, over-limit, or non-activate
uses return structured `rejected/invalid-field`; they never silently fall back
to one-shot `accepted`.

Queues are bounded (`MaxPendingActivations` / `MaxPendingPerAdapter`). Capacity
pressure evicts only completed/expired history; when every slot is non-terminal,
the new activation is rejected with `capacity`. Adapter disconnect, deadline
expiry, owner page change, or wrong-adapter poll/result all fail closed (no
retarget). Lease redelivery can only repeat the same frozen command to the same
adapter.

### Native Messaging wake frames (MV3 idle)

After caller-origin allowlist validation, the `--native` relay emits bounded unsolicited `type=wake` frames on stdout (~`NativeWakeIntervalMs` = 1s). Purpose: inbound Native Messaging traffic wakes the Chrome/Edge MV3 service worker so `poll-activation` can run while the worker would otherwise be idle (JS `setTimeout` alone is not reliable for the 5s activation deadline). Rules:

- Wake frames contain only `protocolVersion`, `type`, `seq` — never session/URL/routing/token/user content.
- Never accepted as inbound route traffic; never forwarded to the daemon; not in `AllowedMessageTypes`.
- Listener-only control messages such as `activate` and `activation-status` are
  rejected by the relay and cannot be smuggled through a browser connection.
- All stdout writes (responses, rejects, wakes) are serialized so 32-bit framing cannot interleave.
- Each serialized stdout frame has one five-second write budget; a browser
  that leaves the pipe open but stops draining it cannot strand the relay.
  Because real Windows anonymous-pipe writes can ignore cancellation, expiry
  terminates only that dedicated `--native` process with a nonzero exit; the
  separately running daemon is unaffected and Chrome/Edge can reconnect.
- On stdin EOF, wake scheduling stops first; a wake frame whose prefix was
  already written completes as one frame, then all accepted forwards drain.
  External cancellation or stdout failure still stops the whole relay, and no
  wake/forward task is orphaned.
- Cancellation while daemon forwarding is in flight is normal relay shutdown;
  it emits neither a synthetic daemon error nor a response on a canceled pipe.
- Disallowed callers get a single reject frame and no wake task.

## Scope note

This directory is self-contained. PowerShell listener integration, browser extension, and PiWebDesktop adapter live outside `windows/route-host/` and are separate slices.
