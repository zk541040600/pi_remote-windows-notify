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
- `routingKey = SHA-256("pi-web-route-v1\\0" + instanceKey + "\\0" + rawSessionId)` (full 256-bit hex).
- Freeze: **0 → miss**, **1 → ready(snapshot)**, **2+ → ambiguous**.
- Snapshots are **immutable**; later registrations never retarget an old notification.
- Activate revalidates adapter + owner lease + pageKey/fingerprint, then relays command/ack.
- Bounded message size (32 KiB), TTL, nonce/requestId replay cache.
- **No raw session IDs or full URLs** in logs or persisted snapshot fields.

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
check. The daemon pipe uses `CurrentUserOnly`; the native relay separately checks the
manifest `allowed_origins` list. Registry registration alone does not install a browser
extension; Chrome and Edge remain inactive until the user loads/configures each extension.

Rerun publish + install to upgrade. Preserve the previous install directory before replacement
when a rollback is required. Restarting the daemon intentionally invalidates all old leases and
snapshots; adapters must re-register, and old notifications remain stale rather than retargeting.

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

Important types: `register-adapter`, `register-owner`, `unregister-owner`, `heartbeat`, `freeze`, `activate`, `poll-activation`, `activate-result`, `activation-status`, `health`.

Results: `ready`, `miss`, `ambiguous`, `stale`, `adapter-unavailable`, `accepted`, `pending`, `session-url-confirmed`, `timeout`, `replay`, `expired`, `rejected`, …

### External adapter activation (polling)

Browser extensions register owners over Native Messaging but cannot receive duplex push from the daemon. Exact activation uses a minimal poll protocol:

1. Listener/broker `activate` → daemon validates snapshot and **enqueues** one bounded command for the frozen `adapterKey`. Immediate result: `accepted` + `activationRequestId` (equals activate `requestId`).
2. Extension `poll-activation` with its `adapterKey` → receives the command **exactly once** (`result=ready` + owner/page/routing fields), or `ok`/`no-pending`.
3. Extension runs tab/window focus, re-reads URL, then `activate-result` with `activationRequestId` + terminal result (`session-url-confirmed` / `stale` / …).
4. Caller `activation-status` with `activationRequestId` → `pending` until terminal, then the final result (TTL-bounded, idempotent).

`--client --json … --wait-ms <ms>` (activate only) polls `activation-status` internally until terminal or deadline — suitable for PowerShell exact-ack without a script-side loop.

Queues are bounded (`MaxPendingActivations` / `MaxPendingPerAdapter`). Adapter disconnect, deadline expiry, owner page change, or wrong-adapter poll/result all fail closed (no retarget, no redelivery).

## Scope note

This directory is self-contained. PowerShell listener integration, browser extension, and PiWebDesktop adapter live outside `windows/route-host/` and are separate slices.
