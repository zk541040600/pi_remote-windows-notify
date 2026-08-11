import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const windowsRoot = new URL("../windows/", import.meta.url);
const readWindows = (name) => readFileSync(new URL(name, windowsRoot), "utf8");

const common = readWindows("NotifyBridge.Common.ps1");
const listener = readWindows("notify-listener.ps1");
const broker = readWindows("pi-notify-broker.ps1");
const popup = readWindows("pi-notify-popup.ps1");
const activate = readWindows("pi-notify-activate.ps1");
const controller = readWindows("paseo-desktop-route.ps1");
const routeTests = readWindows("test-route.ps1");

test("Paseo payload validation rejects error and keeps opaque IDs bounded", () => {
  assert.match(common, /function Resolve-NotifyPaseoRouteMetadata/);
  assert.match(common, /finished', 'permission'/);
  assert.match(common, /MaxLength = 256/);
  assert.match(common, /\$serverIdIsString = \$routeObj\.serverId -is \[string\]/);
  assert.match(common, /routeVersionRaw \+ ''\)\.Trim\(\) -ne '1'/);
  assert.match(common, /\[\\x00-\\x1F\\x7F-\\x9F\]/);
  assert.match(listener, /paseo-route-metadata-invalid[\s\S]*-Body 'invalid'[\s\S]*continue/);
  assert.match(listener, /suppressed-active-agent/);
  assert.match(common, /if \(\$kind -eq 'paseo'\) \{ return 'Paseo' \}/);
  assert.match(listener, /\$originPart[\s\S]*\$signature/);
  assert.match(listener, /OriginKind 'paseo' -CheckOnly/);
  assert.match(listener, /Record five-second dedup only after the desktop path accepted the display/);
  // QQ mirror includes Paseo after desktop display; exclusion branch must stay gone.
  assert.match(listener, /Start-NotifyQqDispatch -Title \$title -Body \$body/);
  assert.equal(
    (listener.match(/^\s*Start-NotifyQqDispatch -Title \$title -Body \$body\s*$/gm) || []).length,
    1,
  );
  assert.ok(
    !/Paseo stays off the QQ mirror path/.test(listener),
    "Paseo must not be excluded from QQ mirror",
  );
  assert.ok(
    !/if \(\$routeOriginKind -ne 'paseo'\)\s*\{\s*Start-NotifyQqDispatch/.test(listener),
    "QQ dispatch must not be gated behind originKind != paseo",
  );
  const paseoFingerprint = listener.indexOf("Get-NotifyPaseoTargetFingerprint");
  const paseoDedup = listener.indexOf("Test-NotifyDuplicateDrop", paseoFingerprint);
  const paseoSave = listener.indexOf("Save-NotifyPaseoActivationUnlessClosed", paseoDedup);
  assert.ok(paseoFingerprint < paseoDedup && paseoDedup < paseoSave, "Paseo dedup must use agent identity before cache creation");
  assert.ok(
    listener.indexOf("Test-NotifyPaseoForegroundActiveAgent") <
      listener.indexOf("Save-NotifyPaseoActivationUnlessClosed"),
    "foreground suppression must happen before activation persistence",
  );
});

test("Paseo activation cache is DPAPI protected, bounded, atomic, and owner leased", () => {
  assert.match(common, /protectedPaseoServerId\s*=\s*Protect-NotifyBridgeValue/);
  assert.match(common, /protectedPaseoWorkspaceId\s*=\s*Protect-NotifyBridgeValue/);
  assert.match(common, /protectedPaseoAgentId\s*=\s*Protect-NotifyBridgeValue/);
  assert.match(common, /Local\\PiRemotePaseoActivationCache/);
  assert.match(common, /Clear-NotifyPaseoActivationCache -MaxAgeSeconds 1800 -MaxCount 95/);
  assert.match(common, /activation-\*\.json\.tmp-\*/);
  // PS5.1 binding turns $null into an empty string and File.Replace then throws
  // "illegal path" while normalizing the backup argument; [NullString]::Value is required.
  assert.match(common, /\[System\.IO\.File\]::Replace\(\$tempPath, \$path, \[NullString\]::Value\)/);
  assert.doesNotMatch(common, /\[System\.IO\.File\]::Replace\([^\r\n]*\$null\)/);
  assert.match(common, /\$payload\.leaseId = \$leaseId/);
  assert.match(common, /\[string\]\$payload\.leaseId -ne \$LeaseId/);
  assert.match(common, /Consume-NotifyPaseoActivationState -ActivationId \$ActivationId -LeaseId \$lease\.LeaseId/);
  const popupCleanupStart = common.indexOf("function Clear-NotifyBridgePopupArtifacts");
  const popupCleanup = common.slice(popupCleanupStart, popupCleanupStart + 5000);
  assert.doesNotMatch(popupCleanup, /paseo-activation/);
});

test("Paseo CDP controller trusts only the expected process, app target, and exact port", () => {
  assert.match(controller, /owner-path-mismatch/);
  assert.match(controller, /Import-Module NetTCPIP -ErrorAction Stop/);
  assert.match(controller, /ProcessQueryLimitedInformation = 0x1000/);
  assert.match(controller, /QueryFullProcessImageName/);
  assert.match(controller, /Get-NotifyPaseoLimitedProcessPath -ProcessId \$ownerId/);
  assert.match(controller, /Chrome_WidgetWin_1/);
  assert.match(controller, /FindMainWindows\(\$OwnerProcessId\)/);
  assert.match(controller, /multiple-main-windows/);
  assert.match(controller, /ShowWindowAsync/);
  assert.match(controller, /IsIconic/);
  assert.match(controller, /RestoreIfMinimized/);
  assert.match(controller, /PaseoWindowNativeV2/);
  // SW_RESTORE unmaximizes; only restore when iconic/minimized.
  assert.match(controller, /if \(IsIconic\(window\)\)/);
  assert.ok(
    controller.includes("RestoreIfMinimized(window)"),
    "foreground path must call RestoreIfMinimized",
  );
  assert.ok(
    !/ShowWindowAsync\(window,\s*9\);\s*[\r\n]+\s*BringWindowToTop/.test(controller),
    "FocusWindow must not force SW_RESTORE before BringWindowToTop",
  );
  assert.ok(
    !/ShowWindowAsync\(\$window,\s*9\)/.test(controller),
    "outer foreground path must not force SW_RESTORE on $window",
  );
  assert.match(controller, /AttachThreadInput/);
  assert.match(controller, /BringWindowToTop/);
  assert.match(controller, /FocusWindow/);
  assert.match(controller, /\$refocusAttempted/);
  assert.match(controller, /workspace-tab-agent_/);
  assert.match(controller, /Array\.from\(new Set\(/);
  assert.match(controller, /aria-selected=\"true\"/);
  assert.match(controller, /selectedAgentCount/);
  assert.match(controller, /selectedAgentIds/);
  assert.match(controller, /\$selectedAgentIds -contains \$agent/);
  assert.match(controller, /pageUri\.Scheme -ne 'paseo'/);
  assert.match(controller, /pageUri\.Host -ne 'app'/);
  assert.match(controller, /wsUri\.Port -ne \$Port/);
  assert.match(controller, /expectedWsPath = '\/devtools\/page\/\{0\}' -f \$targetId/);
  assert.match(controller, /actualWsPath\.Equals\(\$expectedWsPath/);
  assert.match(controller, /multiple-exact-agent/);
  assert.match(controller, /multiple-exact-server/);
  assert.ok(
    controller.indexOf("$exactAgent") < controller.indexOf("$exactServer"),
    "exact-agent selection must precede exact-server selection",
  );
  assert.match(controller, /paseo:web-notification-click/);
  assert.match(controller, /atob\('\$b64'\)/);
  assert.match(controller, /handlerAck: !!event\.defaultPrevented/);
  assert.match(controller, /exact-agent-not-foreground/);
  assert.match(routeTests, /select-multi-panel-agent-ok/);
  assert.match(routeTests, /select-multi-panel-agent-ambiguous/);
  assert.doesNotMatch(controller, /Page\.navigate/);
  assert.doesNotMatch(controller, /paseo:\/\//);
});

test("Every Paseo display and click entry uses the opaque handle without Terminal fallback", () => {
  assert.match(listener, /FocusTarget '' -CwdBase '' -TabTitle '' -SessionName ''[\s\S]{0,220}OriginKind 'paseo' -NotificationId \$routeNotificationId -SnapshotId \$routeSnapshotId/);
  assert.match(listener, /toast\.Tag = \$notificationId/);
  assert.match(listener, /toast\.Group = \$TargetFingerprint/);
  assert.match(listener, /TtlSeconds \$activationTtlSeconds/);
  assert.match(broker, /originKind -eq 'paseo'[\s\S]{0,160}snapshotId/);
  assert.match(broker, /return Start-NotifyBrokerPaseoWorker/);
  assert.match(broker, /Complete-NotifyBrokerPopupLifecycle[^\n]+-Retryable \$(true|false|retryable)/);
  assert.match(broker, /if \(\[string\]\$Tag\.OriginKind -ne 'paseo'\) \{ \$Tag\.Timer\.Stop\(\) \}/);
  assert.match(broker, /broker-popup-replace-same-target/);
  assert.match(listener, /Get-NotifyPopupStackPlan -TargetKey \$targetKey -TargetFingerprint \$targetFingerprint/);
  assert.match(popup, /OriginKind -eq 'paseo'[\s\S]{0,160}SnapshotId/);
  assert.match(popup, /Start-NotifyPopupPaseoWorker[\s\S]*NotifyPopupDidActivate = \$false/);
  assert.match(popup, /Complete-NotifyPopupLifecycle[^\n]+-Retryable \$(true|false|retryable)/);
  assert.match(popup, /NotifyPopupTargetOriginKind -ne 'paseo'\) \{ \$script:NotifyPopupTimer\.Stop\(\) \}/);
  assert.match(activate, /Invoke-NotifyActivationStrategy/);
  assert.match(activate, /if \(\$originKind -eq 'paseo'\)[\s\S]*exit 1/);
  assert.match(activate, /PI_NOTIFY_NOTIFICATION_ID'\] = \$notificationId/);
  assert.match(activate, /PI_NOTIFY_SNAPSHOT_ID'\] = \$snapshotId/);
  assert.match(activate, /outcome\.Result -ne 'busy'|\$outcome\.Result -ne 'busy'/);
  assert.match(activate, /'-ConfigPath', \(\[string\]\$config\.ConfigPath\)/);
  const paseoRetry = activate.slice(activate.indexOf("if ($originKind -eq 'paseo')"));
  assert.doesNotMatch(
    paseoRetry,
    /Invoke-NotifyTerminalRouteActivate|Focus-NotifyWindow|WindowsTerminal/,
  );
});

test("Paseo runtime files are copied everywhere but never auto-enabled", () => {
  for (const name of [
    "install-remote-windows-notify.ps1",
    "install-windows-autostart.ps1",
    "pi-notify-refresh.ps1",
    "pi-notify-restart-listener.ps1",
  ]) {
    const source = readWindows(name);
    assert.match(source, /paseo-desktop-route\.ps1/, `${name} must copy the controller`);
    assert.match(source, /set-paseo-desktop-routing\.ps1/, `${name} must copy the deployment helper`);
    assert.match(source, /set-paseo-built-in-notifications\.ps1/, `${name} must copy the built-in notification helper`);
    assert.doesNotMatch(source, /set-paseo-desktop-routing\.ps1[^\r\n]*-Enable/);
    assert.doesNotMatch(source, /set-paseo-built-in-notifications\.ps1[^\r\n]*-(Disable|Restore)/);
  }
  const helper = readWindows("set-paseo-desktop-routing.ps1");
  assert.match(helper, /remote-debugging-address=127\.0\.0\.1/);
  assert.match(helper, /Standard Paseo executable was not found/);
  assert.match(helper, /Get-NotifyPaseoCdpOwnerSnapshot/);
  assert.doesNotMatch(helper, /Stop-Process|taskkill/);

  const builtIn = readWindows("set-paseo-built-in-notifications.ps1");
  assert.match(builtIn, /\[switch\]\$Disable/);
  assert.match(builtIn, /\[switch\]\$Restore/);
  assert.match(
    builtIn,
    /HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\electron\.app\.Paseo/,
  );
  assert.match(builtIn, /paseo-built-in-notification-state\.json/);
  assert.match(builtIn, /\[System\.IO\.File\]::Replace\(\$tempPath, \$Path, \[NullString\]::Value\)/);
  assert.doesNotMatch(builtIn, /\[System\.IO\.File\]::Replace\([^\r\n]*\$null\)/);
  assert.match(builtIn, /Only HKCU registry paths are allowed/);
  assert.match(builtIn, /HKLM registry paths are forbidden/);
  assert.match(builtIn, /RegistryPath and StatePath test overrides must be provided together/);
  assert.match(builtIn, /StatePath override must stay under USERPROFILE or TEMP/);
  assert.match(builtIn, /backup belongs to a different registry path/);
  assert.match(builtIn, /registryPath = \$RegistryPath/);
  assert.doesNotMatch(builtIn, /systemctl|Stop-Process|taskkill|ssh /);
  assert.doesNotMatch(builtIn, /install-windows-autostart|pi-notify-refresh/);
  // Must not open or write HKLM; rejection text is allowed.
  assert.doesNotMatch(builtIn, /New-ItemProperty[^\n]*HKLM|Get-Item[^\n]*HKLM|Remove-ItemProperty[^\n]*HKLM/i);
  // Backup must capture original presence/value before writing 0, and never overwrite an existing backup.
  assert.match(builtIn, /Save-NotifyPaseoBuiltInOriginalStateOnce/);
  assert.match(builtIn, /never overwrite an existing original backup with 0/);
  assert.match(builtIn, /Restore fail-closed: no built-in notification backup state exists/);
  assert.match(builtIn, /Remove-ItemProperty -LiteralPath \$RegistryPath -Name 'Enabled'/);

  const remoteInstaller = readWindows("install-remote-windows-notify.ps1");
  assert.match(
    remoteInstaller,
    /\$remoteConfig(?:\.paseoLeaseGateEnabled|\[['"]paseoLeaseGateEnabled['"]\])\s*=\s*\[bool\]\$config\.PaseoLeaseGateEnabled/,
  );
  assert.match(
    remoteInstaller,
    /\$remoteConfig(?:\.paseoLeasePath|\[['"]paseoLeasePath['"]\])\s*=\s*\[string\]\$config\.PaseoLeasePath/,
  );

  const check = readWindows("pi-notify-check.ps1");
  assert.match(check, /set-paseo-built-in-notifications\.ps1/);
  assert.match(check, /expectedPaseoLeaseGate/);
  assert.match(check, /ConvertTo-NotifyBridgeBoolean -Value \$cfg\.paseoLeaseGateEnabled -Default \$false/);
  assert.match(check, /OK paseo lease gate enabled=/);
  assert.match(check, /\$remoteGateSuccess = \$remoteText -match/);
  assert.match(
    check,
    /\$remoteSuccessByOutput = \([^\r\n]*\$remoteGateSuccess[^\r\n]*\$remoteRouteSuccess\)/,
  );
  assert.match(
    check,
    /\$remoteExitCodeText -eq '0' -and \$remoteGateSuccess -and \$remoteRouteSuccess/,
  );
  assert.match(check, /must never auto-run Paseo built-in notification Disable\/Restore/);
  assert.doesNotMatch(check, /set-paseo-built-in-notifications\.ps1\s+-(Disable|Restore)/);
});


test("Paseo authenticated health capability is token-protected with fixed schema", () => {
  assert.match(listener, /\/paseo\/health/);
  assert.match(listener, /Get-NotifyPaseoHealthSnapshot/);
  assert.match(listener, /ConvertTo-NotifyPaseoHealthJson/);
  assert.match(common, /function Get-NotifyPaseoHealthSnapshot/);
  assert.match(common, /function ConvertTo-NotifyPaseoHealthJson/);
  assert.match(common, /routeState\s*=\s*\[string\]\$Snapshot\.routeState/);
  assert.match(common, /existingClickEventV1\s*=\s*\$true/);
  assert.match(common, /notifyV1\s*=\s*\$true/);
  assert.match(common, /closeV1\s*=\s*\$true/);
  assert.match(common, /RouteState = 'app-absent'/);
  assert.match(common, /RouteState = 'disabled'/);
  assert.match(common, /RouteState = 'non-loopback'/);
  assert.match(common, /RouteState = 'foreign-owner'/);
  assert.match(common, /function Test-NotifyPaseoPersistedElectronFlags/);
  assert.match(common, /addr -eq '127\.0\.0\.1'/);
  assert.match(common, /remote-debugging-port=/);
  // Unauthenticated GET /health remains; authenticated health requires token via shared POST gate.
  assert.match(listener, /GET' -and \$path -eq '\/health'/);
  const tokenIdx = listener.indexOf("X-Pi-Notify-Token");
  const healthHandlerIdx = listener.indexOf("if ($path -eq '/paseo/health')");
  const closeHandlerIdx = listener.indexOf("if ($path -eq '/paseo/close')");
  assert.ok(tokenIdx > 0 && healthHandlerIdx > tokenIdx, "paseo health handler must be behind token check");
  assert.ok(closeHandlerIdx > tokenIdx, "paseo close handler must be behind token check");
  const healthFn = common.slice(common.indexOf("function Get-NotifyPaseoHealthSnapshot"), common.indexOf("function ConvertTo-NotifyPaseoHealthJson"));
  assert.doesNotMatch(healthFn, /Stop-Process|taskkill|Page\.navigate|SetEnvironmentVariable/);

  // The target-list helper returns a wrapper. Readiness must validate Ok and inspect .Targets.
  const routeReadyFn = common.slice(common.indexOf("function Get-NotifyPaseoRouteReadyState"), common.indexOf("function Get-NotifyPaseoHealthSnapshot"));
  assert.match(routeReadyFn, /\$response = Get-NotifyPaseoCdpTargetList/);
  assert.match(routeReadyFn, /Get-NotifyPaseoCdpTargetReadyState -Response \$response/);
  assert.doesNotMatch(routeReadyFn, /\$targets = @\(Get-NotifyPaseoCdpTargetList/);
  const targetReadyFn = common.slice(common.indexOf("function Get-NotifyPaseoCdpTargetReadyState"), common.indexOf("function Get-NotifyPaseoRouteReadyState"));
  assert.match(targetReadyFn, /Response\.Targets/);
  assert.match(targetReadyFn, /Response\.Ok -isnot \[bool\]/);

  // Only a proven empty listener set maps to app-absent; probe uncertainty is distinct.
  assert.match(controller, /Get-NetTCPConnection -State Listen -ErrorAction Stop/);
  assert.match(controller, /Result\s*=\s*'probe-error'/);
  assert.match(controller, /Reason\s*=\s*'no-listener'/);
  assert.match(routeTests, /paseo-owner-app-absent-ready/);
  assert.match(routeTests, /paseo-owner-probe-error-not-app-absent/);
  assert.match(routeTests, /paseo-health-live-target-wrapper-ready/);
  assert.match(routeTests, /paseo-health-malformed-target-fail-closed/);
});

test("Paseo exact idempotent close uses notification UUID tombstone and never falls back", () => {
  assert.match(listener, /\/paseo\/close/);
  assert.match(listener, /Resolve-NotifyPaseoCloseRequest/);
  assert.match(listener, /Invoke-NotifyPaseoCloseByNotificationId/);
  assert.match(listener, /Test-NotifyPaseoCloseTombstone/);
  assert.match(listener, /paseo-close-tombstone-hit[\s\S]{0,300}-Body 'dedup'/);
  assert.match(common, /function Save-NotifyPaseoCloseTombstone/);
  assert.match(common, /function Revoke-NotifyPaseoActivationByNotificationId/);
  assert.match(common, /function Revoke-NotifyPaseoToastActivationPointers/);
  assert.match(common, /paseo-close-tombstone/);
  assert.match(common, /MaxCount = 96/);
  assert.match(common, /Local\\PiRemotePaseoClose_/);
  assert.match(common, /function Close-NotifyBrokerPaseoByNotificationId|Invoke-NotifyBrokerPaseoCloseByNotificationId/);
  assert.match(broker, /function Close-NotifyBrokerPaseoByNotificationId/);
  assert.match(broker, /closeOriginKind -eq 'paseo'[\s\S]{0,200}Close-NotifyBrokerPaseoByNotificationId/);
  assert.match(popup, /Test-NotifyPaseoCloseTombstone/);
  assert.match(popup, /Get-NotifyPaseoCloseEventName|NotifyPopupPaseoCloseEvent/);
  assert.match(popup, /source="paseo-close"/);
  assert.match(listener, /History\.RemoveGroup\(\$TargetFingerprint/);
  assert.match(listener, /toast\.Tag = \$notificationId/);
  assert.match(common, /History\.Remove\(\$tag, \$group, \$ToastAppId\)/);
  // Close response contract
  assert.match(listener, /paseo-close-invalid[\s\S]{0,400}-Body 'invalid'/);
  assert.match(listener, /paseo-close result=ok[\s\S]{0,300}-Body 'ok'/);
  // No process kill for fallback close
  assert.doesNotMatch(popup, /Stop-Process|taskkill/);
  const closeFn = common.slice(common.indexOf("function Invoke-NotifyPaseoCloseByNotificationId"), common.indexOf("function Get-NotifyPaseoPersistedElectronFlags"));
  assert.doesNotMatch(closeFn, /Stop-Process|taskkill/);

  const closeRequestFn = common.slice(common.indexOf("function Resolve-NotifyPaseoCloseRequest"));
  assert.match(closeRequestFn, /\$allowed = @\('originKind', 'version', 'notificationId'\)/);
  assert.match(closeRequestFn, /\$properties\.Count -ne \$allowed\.Count/);
  assert.match(routeTests, /paseo-close-rejects-benign-extra-field/);

  const tombstoneFn = common.slice(common.indexOf("function Test-NotifyPaseoCloseTombstonePayload"), common.indexOf("function Save-NotifyPaseoCloseTombstone"));
  assert.match(tombstoneFn, /Payload\.version/);
  assert.match(tombstoneFn, /ExpectedFingerprint/);
  assert.match(tombstoneFn, /expiresAtTicks -le \$nowTicks/);
  assert.match(tombstoneFn, /AddSeconds\(1800\)/);
  assert.match(routeTests, /paseo-tombstone-partial-does-not-suppress/);
  assert.match(routeTests, /paseo-tombstone-fingerprint-mismatch-does-not-suppress/);
  assert.match(routeTests, /paseo-close-wins-notify-race/);
  assert.match(routeTests, /paseo-close-revokes-exact-toast-pointer/);
  assert.match(routeTests, /paseo-close-old-preserves-new-toast-pointer/);
  assert.match(broker, /broker-popup-drop paseo-close-tombstone/);
});

test("Fallback popup has an exact close timer independent from activation", () => {
  const activatingFn = popup.slice(
    popup.indexOf("function Set-NotifyPopupActivating"),
    popup.indexOf("function Request-NotifyPopupExactWorkerStop"),
  );
  assert.doesNotMatch(activatingFn, /NotifyPopupPaseoCloseTimer\.Stop/);
  assert.match(popup, /NotifyPopupPaseoCloseTimer = New-Object System\.Windows\.Forms\.Timer/);
  assert.match(popup, /Test-NotifyPaseoCloseSignal -NotificationId \$targetNotificationId/);
  assert.match(popup, /Request-NotifyPopupExactWorkerStop -Reason 'paseo-close'/);
  assert.match(popup, /NotifyPopupPaseoCloseTimer\.Dispose\(\)/);
  assert.match(routeTests, /paseo-close-signal-visible-during-activation/);
});

