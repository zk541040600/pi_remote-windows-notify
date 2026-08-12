import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const windowsRoot = new URL("../windows/", import.meta.url);

test("recovery tickets propagate to every Windows notification entry point", () => {
  const listener = readFileSync(new URL("notify-listener.ps1", windowsRoot), "utf8");
  const broker = readFileSync(new URL("pi-notify-broker.ps1", windowsRoot), "utf8");
  const popup = readFileSync(new URL("pi-notify-popup.ps1", windowsRoot), "utf8");
  const activate = readFileSync(new URL("pi-notify-activate.ps1", windowsRoot), "utf8");

  assert.match(listener, /protectedRecoveryTicketId/);
  assert.match(listener, /Start-NotifyToastRecoveryWorker/);
  assert.match(
    listener,
    /\$toast\.ExpirationTime = if \(\$isPendingRecoveryToast\)[\s\S]*AddSeconds\(115\)[\s\S]*AddMinutes\(5\)/,
    "pending-ticket toasts must expire before their two-minute ticket",
  );
  assert.match(broker, /BeginInvoke\(\)/);
  assert.match(broker, /Start-NotifyBrokerExactWorker[^\r\n]*-Mode 'resolve'/);
  assert.match(popup, /BeginInvoke\(\)/);
  assert.match(popup, /Start-NotifyPopupExactWorker -Mode 'resolve'/);
  const popupClick = popup.slice(
    popup.indexOf("$activateAction = {"),
    popup.indexOf("$closeAction = {"),
  );
  assert.match(popupClick, /Set-NotifyPopupActivating/);
  assert.match(popupClick, /Request-NotifyPopupExactWorkerStop -Reason 'superseded-by-activation'/);
  assert.match(activate, /protectedRecoveryTicketId/);
  assert.match(activate, /Invoke-NotifyActivationStrategy/);
  const activation = readFileSync(new URL("NotifyBridge.Activation.ps1", windowsRoot), "utf8");
  assert.match(activation, /Invoke-NotifyExactRouteRecoveryAndActivate/);

  const exactRouteBlock = activate.slice(activate.indexOf("if ($originKind -eq 'pi-web')"));
  assert.doesNotMatch(exactRouteBlock, /activate-route-downgrade/);
  assert.match(
    exactRouteBlock,
    /activate-route-fail-closed[\s\S]*exit 1/,
    "a transient exact-route recovery result must not fall through to Terminal focus",
  );
  assert.doesNotMatch(
    exactRouteBlock,
    /Invoke-NotifyTerminalRouteActivate|Focus-NotifyWindow/,
    "pi-web fail-closed must never fall through to Terminal",
  );
});

test("popup feedback has bounded click recovery and an independent terminal close", () => {
  const broker = readFileSync(new URL("pi-notify-broker.ps1", windowsRoot), "utf8");
  const popup = readFileSync(new URL("pi-notify-popup.ps1", windowsRoot), "utf8");

  const activation = readFileSync(new URL("NotifyBridge.Activation.ps1", windowsRoot), "utf8");
  for (const [source, prefix] of [
    [broker, "NotifyBroker"],
    [popup, "NotifyPopup"],
  ]) {
    assert.match(source, new RegExp(`\\$script:${prefix}FailureCloseDelayMs = 2500`));
    assert.match(source, new RegExp(`\\$script:${prefix}ActivationRecoveryWaitMs = 10000`));
    assert.match(source, new RegExp(`\\$script:${prefix}RecoveringActivationWatchdogMs = 12000`));
    assert.match(source, new RegExp(`\\$script:${prefix}ReadyActivationWatchdogMs = 20000`));
    assert.match(source, /Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc/);
    assert.match(source, /Get-NotifyActivationWorkerScript|Invoke-NotifyActivationStrategy/);
    assert.match(source, /ActivationRecoveryWaitMs/);
    assert.match(source, /FailureCloseTimer[^\r\n]*\.Start\(\)/);
    assert.match(source, /ActivationWatchdogTimer[^\r\n]*\.Start\(\)/);
  }
  assert.match(activation, /Wait-NotifyExactRouteRecovery[^\r\n]*-WaitMs 125000/);
  assert.match(
    activation,
    /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs \$ActivationRecoveryWaitMs/,
    "a click without a snapshot must use the short recovery budget",
  );
  assert.match(
    activation,
    /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-ActivateWaitMs 45000 -ActivateTimeoutMs 48000/,
    "exact activation must preserve a 45-second background proof budget",
  );
  assert.doesNotMatch(
    activation,
    /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs 125000/,
    "the 125-second passive resolver budget must never leak into click handling",
  );

  const brokerActivating = broker.slice(
    broker.indexOf("function Set-NotifyBrokerPopupActivating"),
    broker.indexOf("function Show-NotifyBrokerPopup"),
  );
  assert.match(brokerActivating, /opening-title/);
  assert.match(brokerActivating, /opening-body/);
  assert.doesNotMatch(
    brokerActivating,
    /CloseLabel\.Text\s*=/,
    "the close affordance must remain visible during activation feedback",
  );

  const popupActivating = popup.slice(
    popup.indexOf("function Set-NotifyPopupActivating"),
    popup.indexOf("function Request-NotifyPopupExactWorkerStop"),
  );
  assert.match(popupActivating, /opening-title/);
  assert.match(popupActivating, /opening-body/);
  assert.doesNotMatch(popupActivating, /NotifyPopupCloseLabel\.Text\s*=/);

  const popupFormClosedStart = popup.indexOf("$form.Add_FormClosed({");
  const popupFormClosedEnd = popup.indexOf("\n})", popupFormClosedStart);
  const popupFormClosed = popup.slice(popupFormClosedStart, popupFormClosedEnd);
  assert.match(
    popupFormClosed,
    /Request-NotifyPopupExactWorkerStop -Reason 'popup-closed'/,
    "closing the fallback popup must reuse asynchronous worker cancellation",
  );
  assert.doesNotMatch(
    popupFormClosed,
    /\.PowerShell\.(?:Stop|Dispose|EndInvoke|EndStop)\(/,
    "FormClosed must never synchronously stop or dispose a worker on the UI thread",
  );
  assert.doesNotMatch(
    popupFormClosed,
    /\.Runspace\.(?:Close|Dispose)\(/,
    "FormClosed must leave runspace reclamation to process teardown",
  );

  const oldestActivation = broker.slice(
    broker.indexOf("function Invoke-NotifyBrokerOldestPopupActivation"),
    broker.indexOf("function Get-NotifyBrokerRecoveryUiText"),
  );
  assert.match(oldestActivation, /foreach \(\$entry in \$entries\)/);
  assert.match(oldestActivation, /skip terminal-or-unavailable/);
  assert.match(oldestActivation, /no-eligible-popups/);
});

test("desktop focus progress never closes Pi Web feedback (non-terminal pending)", () => {
  const common = readFileSync(new URL("NotifyBridge.Common.ps1", windowsRoot), "utf8");
  const broker = readFileSync(new URL("pi-notify-broker.ps1", windowsRoot), "utf8");
  const popup = readFileSync(new URL("pi-notify-popup.ps1", windowsRoot), "utf8");
  const activate = readFileSync(new URL("pi-notify-activate.ps1", windowsRoot), "utf8");

  // The exact activate helper must wait for the terminal result — it must not
  // opt in to returning on the focused/pending progress phase.
  const exactActivate = common.slice(
    common.indexOf("function Invoke-NotifyExactRouteActivate"),
    common.indexOf("# --- Paseo desktop route helpers"),
  );
  assert.doesNotMatch(
    exactActivate,
    /-ReturnOnProgress/,
    "the exact helper must wait for the terminal activation result",
  );
  assert.match(
    exactActivate,
    /Invoke-NotifyRouteHostClient -Request \$request -WaitMs \$WaitMs -TimeoutMs \$TimeoutMs -Config \$Config\s*\r?\n/,
    "the exact helper must not pass -ReturnOnProgress",
  );
  assert.match(
    common,
    /New-NotifyRouteRequestEnvelope -Type 'activate' -Fields \$fields -TtlMs 5000/,
    "the longer activation deadline must not expand transport-envelope freshness",
  );

  const activation = readFileSync(new URL("NotifyBridge.Activation.ps1", windowsRoot), "utf8");
  for (const source of [broker, popup]) {
    assert.match(source, /ValidateSet\('focused', 'handled', 'failed', 'dismissed'\)/);
    assert.match(source, /ConvertTo-NotifyActivationUiOutcome/);
    assert.match(source, /if \(\$ui\.Action -eq 'keep-focused'\)/);
    assert.doesNotMatch(source, /close-focused/, "focused/pending must never close the card");
  }
  assert.match(activation, /\$decision -eq 'focused'/);
  assert.match(activation, /Action\s+=\s+'keep-focused'/);
  assert.match(activation, /background-proof-pending/);
  assert.doesNotMatch(activation, /close-focused/, "the UI mapping must not close on focused");
  assert.match(activate, /if \(\$ui\.Action -eq 'keep-focused'\)[\s\S]*activate-route-focused background-proof=pending[\s\S]*exit 1/);
  const handledCliBlock = activate.slice(
    activate.indexOf("if ($ui.Action -eq 'close-handled')"),
    activate.indexOf("if ($ui.Action -eq 'keep-focused')"),
  );
  assert.match(handledCliBlock, /Remove-Item/);
  const pendingCliBlock = activate.slice(
    activate.indexOf("if ($ui.Action -eq 'keep-focused')"),
    activate.indexOf("# Temporary Paseo failure"),
  );
  assert.doesNotMatch(pendingCliBlock, /Remove-Item|exit 0/);
  assert.match(activate, /activate-route-focused background-proof=pending/);
});

test("broker bounds exact-route workers and reclaims them without blocking popup events", () => {
  const broker = readFileSync(new URL("pi-notify-broker.ps1", windowsRoot), "utf8");
  const startWorker = broker.slice(
    broker.indexOf("function Start-NotifyBrokerExactWorker"),
    broker.indexOf("function Queue-NotifyBrokerActivation"),
  );

  assert.match(broker, /\$script:NotifyBrokerExactWorkerMax = 32/);
  assert.match(
    startWorker,
    /NotifyBrokerExactWorkers\.Count -ge \$script:NotifyBrokerExactWorkerMax[\s\S]*resolve-cap-reached[\s\S]*return \$false/,
    "new resolve workers must be rejected at the global cap",
  );
  assert.match(startWorker, /superseded-by-activation/);
  assert.match(broker, /\$script:NotifyBrokerDeferredActivationMax = 32/);
  assert.match(
    broker,
    /\$script:NotifyBrokerDeferredActivations = @\{\}/,
    "deferred user intent must have its own bounded store",
  );
  assert.doesNotMatch(
    startWorker,
    /\$worker\.DeferredActivation|DeferredActivation = \$null/,
    "a resolver worker must never own another popup's activation intent",
  );
  assert.match(
    startWorker,
    /Mode -eq 'activate'[\s\S]*Mode -eq 'resolve'[\s\S]*preempted-by-activation[\s\S]*return \$true/,
    "a user activation must asynchronously reclaim a passive resolver at the cap",
  );
  assert.match(broker, /PowerShell\.BeginStop\(\$null, \$null\)/);
  assert.match(
    broker,
    /StopAsync\.IsCompleted[\s\S]*EndStop\(\$worker\.StopAsync\)[\s\S]*EndInvoke\(\$worker\.Async\)[\s\S]*NotifyBrokerExactWorkers\.Remove\(\$id\)[\s\S]*Start-NotifyBrokerNextDeferredActivation/,
    "the UI timer must reclaim a cancelled resolve before launching its deferred activation",
  );

  const formClosedStart = broker.indexOf("$form.Add_FormClosed({");
  const formClosedEnd = broker.indexOf("\n    })", formClosedStart);
  const formClosed = broker.slice(formClosedStart, formClosedEnd);
  assert.match(
    formClosed,
    /Remove-NotifyBrokerDeferredActivationForPopup -PopupId \$tag\.PopupId/,
  );
  assert.match(
    formClosed,
    /Stop-NotifyBrokerExactWorkersForPopup -PopupId \$tag\.PopupId -Reason 'popup-closed'/,
  );
  assert.doesNotMatch(formClosed, /\.PowerShell\.(?:Stop|EndInvoke)\(/);
  assert.match(broker, /Stop-NotifyBrokerAllExactWorkers -Reason 'broker-exit'/);
});

test(
  "popup terminal transitions are idempotent and oldest activation skips dead entries",
  { skip: process.platform !== "win32" },
  () => {
    const brokerPath = fileURLToPath(
      new URL("pi-notify-broker.ps1", windowsRoot),
    );
    const popupPath = fileURLToPath(
      new URL("pi-notify-popup.ps1", windowsRoot),
    );
    const activationPath = fileURLToPath(
      new URL("NotifyBridge.Activation.ps1", windowsRoot),
    );
    const harness = String.raw`
$ErrorActionPreference = 'Stop'
function Get-TestFunctionDefinition {
  param([string]$Path, [string]$Name)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "parse failed: $Path" }
  $definition = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $Name
  }, $true))
  if ($definition.Count -ne 1) { throw "missing function: $Name" }
  return $definition[0].Extent.Text
}
function New-FakeTimer {
  $timer = [pscustomobject]@{ StartCalls = 0; StopCalls = 0; Interval = 0 }
  $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.StartCalls += 1 }
  $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.StopCalls += 1 }
  return $timer
}
function New-FakeForm {
  $form = [pscustomobject]@{ IsDisposed = $false; CloseCalls = 0; Tag = $null }
  $form | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.CloseCalls += 1 }
  return $form
}
function Write-NotifyBrokerLog { param([string]$Message) }
function Write-NotifyPopupLog { param([string]$Message) }

. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_BROKER_TEST_PATH -Name 'Complete-NotifyBrokerPopupLifecycle')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_BROKER_TEST_PATH -Name 'Invoke-NotifyBrokerOldestPopupActivation')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_POPUP_TEST_PATH -Name 'Complete-NotifyPopupLifecycle')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_POPUP_TEST_PATH -Name 'Request-NotifyPopupExactWorkerStop')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_ACTIVATION_TEST_PATH -Name 'Test-NotifyActivationStrategyResult')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_ACTIVATION_TEST_PATH -Name 'Get-NotifyActivationRemainingMs')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_ACTIVATION_TEST_PATH -Name 'Get-NotifyPiWebActivationWatchdogMs')))
. ([scriptblock]::Create((Get-TestFunctionDefinition -Path $env:PI_NOTIFY_ACTIVATION_TEST_PATH -Name 'ConvertTo-NotifyActivationUiOutcome')))

$watchdogClock = [DateTime]::UtcNow
$longProofWatchdog = Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc $watchdogClock.AddMinutes(1) -NowUtc $watchdogClock
$shortExpiryWatchdog = Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc $watchdogClock.AddMilliseconds(1500) -NowUtc $watchdogClock
$expiredWatchdog = Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc $watchdogClock.AddMilliseconds(-1) -NowUtc $watchdogClock
if ($longProofWatchdog -ne 60000 -or
    $shortExpiryWatchdog -ne 1500 -or
    $expiredWatchdog -ne 1) {
  throw 'Pi Web watchdog must preserve terminal proof budget without extending popup expiry'
}

$script:BrokerUnavailableCalls = 0
function Set-NotifyBrokerRecoveryUiState {
  param([hashtable]$Tag, [string]$State)
  if ($State -eq 'unavailable') { $script:BrokerUnavailableCalls += 1 }
}
$brokerForm = New-FakeForm
$brokerTag = @{
  PopupId = 'terminal-broker'
  Form = $brokerForm
  OriginKind = 'pi-web'
  ExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(1)
  TerminalState = [ref]$false
  CloseRequested = [ref]$false
  TerminalOutcome = ''
  TerminalReason = ''
  Activating = [ref]$true
  Timer = New-FakeTimer
  FocusWatchTimer = New-FakeTimer
  ActivationWatchdogTimer = New-FakeTimer
  FailureCloseTimer = New-FakeTimer
}
$brokerForm.Tag = $brokerTag
$firstFailure = Complete-NotifyBrokerPopupLifecycle -Tag $brokerTag -Outcome 'failed' -Reason 'worker-error'
$repeatFailure = Complete-NotifyBrokerPopupLifecycle -Tag $brokerTag -Outcome 'failed' -Reason 'worker-error-repeat'
$firstDismiss = Complete-NotifyBrokerPopupLifecycle -Tag $brokerTag -Outcome 'dismissed' -Reason 'failure-auto-close'
$repeatDismiss = Complete-NotifyBrokerPopupLifecycle -Tag $brokerTag -Outcome 'dismissed' -Reason 'failure-auto-close-repeat'
if (-not $firstFailure -or $repeatFailure -or -not $firstDismiss -or $repeatDismiss -or
    $brokerTag.FailureCloseTimer.StartCalls -ne 1 -or
    $script:BrokerUnavailableCalls -ne 1 -or
    $brokerForm.CloseCalls -ne 1 -or
    $brokerTag.TerminalOutcome -ne 'failed') {
  throw 'broker terminal lifecycle is not idempotent'
}

$script:PopupUnavailableCalls = 0
function Set-NotifyPopupRecoveryUiState {
  param([string]$State)
  if ($State -eq 'unavailable') { $script:PopupUnavailableCalls += 1 }
}
$script:NotifyPopupForm = New-FakeForm
$script:NotifyPopupTargetOriginKind = 'pi-web'
$script:NotifyPopupExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(1)
$script:NotifyPopupFailureCloseDelayMs = 2500
$script:NotifyPopupTerminalState = $false
$script:NotifyPopupTerminalOutcome = ''
$script:NotifyPopupTerminalReason = ''
$script:NotifyPopupCloseRequested = $false
$script:NotifyPopupActivating = $true
$script:NotifyPopupTimer = New-FakeTimer
$script:NotifyPopupFocusWatchTimer = New-FakeTimer
$script:NotifyPopupActivationWatchdogTimer = New-FakeTimer
$script:NotifyPopupFailureCloseTimer = New-FakeTimer
$firstFailure = Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-error'
$repeatFailure = Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-error-repeat'
$firstDismiss = Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'failure-auto-close'
$repeatDismiss = Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'failure-auto-close-repeat'
if (-not $firstFailure -or $repeatFailure -or -not $firstDismiss -or $repeatDismiss -or
    $script:NotifyPopupFailureCloseTimer.StartCalls -ne 1 -or
    $script:PopupUnavailableCalls -ne 1 -or
    $script:NotifyPopupForm.CloseCalls -ne 1 -or
    $script:NotifyPopupTerminalOutcome -ne 'failed') {
  throw 'fallback popup terminal lifecycle is not idempotent'
}

# Focused/pending must map to a NON-terminal UI action: the card stays open in
# bounded pending feedback and only a final result (or the original deadline)
# closes it. Validate the pure UI mapping against the real strategy validator.
$focusedOutcome = [pscustomobject]@{
  Version = 1; Operation = 'activate'; OriginKind = 'pi-web'
  Decision = 'focused'; Result = 'pending'; Reason = 'background-proof-pending'
  Retryable = $false; ProofState = 'pending'
  SnapshotId = 'snapshot-focused'; RecoveryTicketId = 'ticket'
  ScrollAttempted = $false; ScrolledToBottom = $false; ElapsedMs = 42
}
$focusedUi = ConvertTo-NotifyActivationUiOutcome -Outcome $focusedOutcome
if ($focusedUi.Action -ne 'keep-focused' -or
    $focusedUi.ClaimFinalActivation -ne $false -or
    $focusedUi.Decision -ne 'focused' -or
    $focusedUi.Result -ne 'pending' -or
    $focusedUi.Reason -ne 'background-proof-pending') {
  throw 'focused outcome must map to non-terminal keep-focused'
}
$handledUi = ConvertTo-NotifyActivationUiOutcome -Outcome ([pscustomobject]@{
  Version = 1; Operation = 'activate'; OriginKind = 'pi-web'
  Decision = 'handled'; Result = 'session-url-confirmed'; Reason = ''
  Retryable = $false; ProofState = 'final'
  SnapshotId = 'snapshot-handled'; RecoveryTicketId = ''
  ScrollAttempted = $false; ScrolledToBottom = $false; ElapsedMs = 30
})
if ($handledUi.Action -ne 'close-handled' -or $handledUi.ClaimFinalActivation -ne $true) {
  throw 'handled outcome must remain terminal close-handled'
}
$failedUi = ConvertTo-NotifyActivationUiOutcome -Outcome ([pscustomobject]@{
  Version = 1; Operation = 'activate'; OriginKind = 'pi-web'
  Decision = 'fail-closed'; Result = 'adapter-unavailable'; Reason = 'route-host-missing'
  Retryable = $false; ProofState = 'none'
  SnapshotId = ''; RecoveryTicketId = ''
  ScrollAttempted = $false; ScrolledToBottom = $false; ElapsedMs = 5
})
if ($failedUi.Action -ne 'show-unavailable') {
  throw 'fail-closed outcome must map to show-unavailable'
}

$cancelPowerShell = [pscustomobject]@{ BeginStopCalls = 0; StopCalls = 0 }
$cancelPowerShell | Add-Member -MemberType ScriptMethod -Name BeginStop -Value {
  param($callback, $state)
  $this.BeginStopCalls += 1
  return [pscustomobject]@{ IsCompleted = $false }
}
$cancelPowerShell | Add-Member -MemberType ScriptMethod -Name Stop -Value {
  $this.StopCalls += 1
  throw 'synchronous Stop must not run'
}
$script:NotifyPopupExactWorkerTimer = New-FakeTimer
$script:NotifyPopupExactWorker = [pscustomobject]@{
  Mode = 'activate'
  PowerShell = $cancelPowerShell
  Async = [pscustomobject]@{ IsCompleted = $false }
  StopAsync = $null
  CancelReason = ''
}
$cancelAccepted = Request-NotifyPopupExactWorkerStop -Reason 'popup-closed'
if (-not $cancelAccepted -or
    $cancelPowerShell.BeginStopCalls -ne 1 -or
    $cancelPowerShell.StopCalls -ne 0 -or
    $null -eq $script:NotifyPopupExactWorker.StopAsync -or
    $script:NotifyPopupExactWorker.CancelReason -ne 'popup-closed') {
  throw 'fallback popup close did not request non-blocking cancellation'
}
$script:NotifyPopupExactWorker = $null

function New-OldestTag {
  param([string]$PopupId, [string]$RecoveryState, [bool]$Terminal, [string]$SnapshotId)
  return @{
    PopupId = $PopupId
    OriginKind = 'pi-web'
    RecoveryState = $RecoveryState
    TerminalState = [ref]$Terminal
    ShouldActivate = [ref]$false
    DidActivate = [ref]$false
    Activating = [ref]$false
    ActivationQueued = [ref]$false
    TargetHost = 'host'
    TargetCwdBase = 'cwd'
    TargetSourceTabTitle = 'tab'
    TargetFingerprint = $PopupId
    NotificationId = 'notification'
    SnapshotId = $SnapshotId
    RecoveryTicketId = 'ticket'
    Form = $null
  }
}
$script:ActivatedPopupIds = @()
$script:QueuedPopupIds = @()
function Set-NotifyBrokerPopupActivating {
  param([hashtable]$Tag)
  $script:ActivatedPopupIds += $Tag.PopupId
  return $true
}
function Queue-NotifyBrokerActivation {
  param($TargetHost, $CurrentDirBase, $SourceTabTitleValue, $TargetFingerprint,
    $PopupId, $FormToClose, $OriginKind, $NotificationId, $SnapshotId, $RecoveryTicketId)
  $script:QueuedPopupIds += $PopupId
  return $true
}
$unavailableTag = New-OldestTag -PopupId 'unavailable' -RecoveryState 'unavailable' -Terminal $false -SnapshotId ''
$terminalTag = New-OldestTag -PopupId 'terminal' -RecoveryState 'ready' -Terminal $true -SnapshotId 'snapshot-terminal'
$readyTag = New-OldestTag -PopupId 'ready' -RecoveryState 'ready' -Terminal $false -SnapshotId 'snapshot-ready'
foreach ($tag in @($unavailableTag, $terminalTag, $readyTag)) {
  $form = New-FakeForm
  $form.Tag = $tag
  $tag.Form = $form
}
$script:NotifyBrokerActivePopups = @{
  unavailable = [pscustomobject]@{ PopupId = 'unavailable'; CreatedAtUtc = [datetime]::UtcNow.AddSeconds(-3); Form = $unavailableTag.Form }
  terminal = [pscustomobject]@{ PopupId = 'terminal'; CreatedAtUtc = [datetime]::UtcNow.AddSeconds(-2); Form = $terminalTag.Form }
  ready = [pscustomobject]@{ PopupId = 'ready'; CreatedAtUtc = [datetime]::UtcNow.AddSeconds(-1); Form = $readyTag.Form }
}
$activated = Invoke-NotifyBrokerOldestPopupActivation
if (-not $activated -or
    $script:ActivatedPopupIds.Count -ne 1 -or
    $script:ActivatedPopupIds[0] -ne 'ready' -or
    $script:QueuedPopupIds.Count -ne 1 -or
    $script:QueuedPopupIds[0] -ne 'ready') {
  throw 'oldest activation did not skip unavailable and terminal popups'
}
$script:NotifyBrokerActivePopups.Remove('ready')
if (Invoke-NotifyBrokerOldestPopupActivation) {
  throw 'oldest activation accepted an unavailable or terminal popup'
}
'PASS popup-terminal-lifecycle'
`;
    const result = spawnSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", harness],
      {
        encoding: "utf8",
        timeout: 15_000,
        env: {
          ...process.env,
          PI_NOTIFY_BROKER_TEST_PATH: brokerPath,
          PI_NOTIFY_POPUP_TEST_PATH: popupPath,
          PI_NOTIFY_ACTIVATION_TEST_PATH: activationPath,
        },
      },
    );
    assert.equal(
      result.status,
      0,
      `popup terminal lifecycle regression failed:\n${result.stdout}\n${result.stderr}`,
    );
    assert.match(result.stdout, /PASS popup-terminal-lifecycle/);
  },
);

test(
  "deferred activations survive victim closure and cannot be stolen by an already-cancelled resolver",
  { skip: process.platform !== "win32" },
  () => {
    const brokerPath = fileURLToPath(
      new URL("pi-notify-broker.ps1", windowsRoot),
    );
    const harness = String.raw`
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $env:PI_NOTIFY_BROKER_TEST_PATH,
  [ref]$tokens,
  [ref]$errors)
if ($errors.Count -ne 0) { throw 'broker parse failed' }
$wanted = @(
  'Request-NotifyBrokerExactWorkerStop',
  'Add-NotifyBrokerDeferredActivation',
  'Remove-NotifyBrokerDeferredActivationForPopup',
  'Take-NotifyBrokerDeferredActivation',
  'Test-NotifyBrokerActivationIntent',
  'Start-NotifyBrokerNextDeferredActivation',
  'Start-NotifyBrokerExactWorker')
foreach ($name in $wanted) {
  $definition = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $name
  }, $true))
  if ($definition.Count -ne 1) { throw "missing function: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
function Write-NotifyBrokerLog { param([string]$Message) }
function Set-NotifyBrokerExactWorkerFailClosed {
  param([string]$PopupId, [string]$Reason)
  $script:FailClosed += "$PopupId/$Reason"
}

function New-FakeResolver {
  param(
    [string]$PopupId,
    [string]$CancelReason = '',
    [object]$StopAsync = $null,
    [datetime]$StartedAtUtc = [datetime]::UtcNow)

  $fakePowerShell = [pscustomobject]@{ BeginStopCalls = 0 }
  $fakePowerShell | Add-Member -MemberType ScriptMethod -Name BeginStop -Value {
    param($callback, $state)
    $this.BeginStopCalls += 1
    return [pscustomobject]@{ IsCompleted = $false }
  }
  return [pscustomobject]@{
    PopupId = $PopupId
    Mode = 'resolve'
    PowerShell = $fakePowerShell
    Async = [pscustomobject]@{ IsCompleted = $false }
    StopAsync = $StopAsync
    CancelReason = $CancelReason
    StartedAtUtc = $StartedAtUtc
  }
}

$script:NotifyBrokerExactWorkerMax = 1
$script:NotifyBrokerDeferredActivationMax = 32
$script:NotifyBrokerDeferredActivationSequence = 0
$script:NotifyBrokerDeferredActivations = @{}
$script:NotifyBrokerActivePopups = @{ 'popup-a' = [pscustomobject]@{} }
$script:FailClosed = @()

# A user click preempts resolver V. Closing V must not erase target A because
# V no longer owns A's queued intent.
$victim = New-FakeResolver -PopupId 'popup-victim'
$script:NotifyBrokerExactWorkers = @{ victim = $victim }
$accepted = Start-NotifyBrokerExactWorker -PopupId 'popup-a' -Mode 'activate' -NotificationId 'notification-a' -RecoveryTicketId 'ticket-a'
if (-not $accepted -or
    $victim.CancelReason -ne 'preempted-by-activation' -or
    -not $script:NotifyBrokerDeferredActivations.ContainsKey('popup-a')) {
  throw 'activation A was not queued against victim V'
}
[void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $victim.PopupId)
$stopped = Request-NotifyBrokerExactWorkerStop -Worker $victim -Reason 'popup-closed'
if (-not $stopped -or
    $victim.CancelReason -ne 'preempted-by-activation' -or
    -not $script:NotifyBrokerDeferredActivations.ContainsKey('popup-a')) {
  throw 'victim close erased deferred activation'
}

# Resolver A may already be stopping to make room for activation B. A later
# click on popup A must preempt another live resolver C; it must not report
# success merely because the already-cancelled resolver A exists.
$script:NotifyBrokerExactWorkerMax = 2
$script:NotifyBrokerDeferredActivations = @{}
$resolverA = New-FakeResolver -PopupId 'popup-a' -CancelReason 'preempted-by-activation' -StopAsync ([pscustomobject]@{ IsCompleted = $false }) -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-2))
$resolverC = New-FakeResolver -PopupId 'popup-c' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-1))
$script:NotifyBrokerExactWorkers = @{ resolverA = $resolverA; resolverC = $resolverC }
[void](Add-NotifyBrokerDeferredActivation -PopupId 'popup-b' -NotificationId 'notification-b' -RecoveryTicketId 'ticket-b')
$accepted = Start-NotifyBrokerExactWorker -PopupId 'popup-a' -Mode 'activate' -NotificationId 'notification-a' -RecoveryTicketId 'ticket-a'
if (-not $accepted -or
    -not $script:NotifyBrokerDeferredActivations.ContainsKey('popup-a') -or
    -not $script:NotifyBrokerDeferredActivations.ContainsKey('popup-b') -or
    $resolverA.CancelReason -ne 'preempted-by-activation' -or
    $resolverA.PowerShell.BeginStopCalls -ne 0 -or
    $resolverC.CancelReason -ne 'preempted-by-activation' -or
    $resolverC.PowerShell.BeginStopCalls -ne 1) {
  throw 'already-cancelled resolver A stole or stranded its own activation'
}
if (-not (Test-NotifyBrokerActivationIntent -PopupId 'popup-a')) {
  throw 'queued activation A was mistaken for an unavailable preemption victim'
}

# Closing target A suppresses A only; unrelated target B remains queued.
[void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId 'popup-a')
if ($script:NotifyBrokerDeferredActivations.ContainsKey('popup-a') -or
    -not $script:NotifyBrokerDeferredActivations.ContainsKey('popup-b')) {
  throw 'target close suppressed the wrong deferred activation'
}

# The bounded queue deduplicates by target popup and fails closed at capacity.
$script:NotifyBrokerDeferredActivationMax = 1
$script:NotifyBrokerDeferredActivations = @{}
$firstAdded = Add-NotifyBrokerDeferredActivation -PopupId 'popup-a' -NotificationId 'notification-a'
$duplicateAdded = Add-NotifyBrokerDeferredActivation -PopupId 'popup-a' -NotificationId 'notification-a-duplicate'
$overflowAdded = Add-NotifyBrokerDeferredActivation -PopupId 'popup-b' -NotificationId 'notification-b'
if (-not $firstAdded -or -not $duplicateAdded -or $overflowAdded -or $script:NotifyBrokerDeferredActivations.Count -ne 1) {
  throw 'deferred activation queue is not bounded and idempotent'
}

# Once a slot is reclaimed, a queued target starts exactly once.
$script:NotifyBrokerDeferredActivationMax = 32
$script:NotifyBrokerExactWorkers = @{}
$script:NotifyBrokerActivePopups = @{ 'popup-a' = [pscustomobject]@{} }
$script:NotifyBrokerDeferredActivations = @{}
[void](Add-NotifyBrokerDeferredActivation -PopupId 'popup-a' -NotificationId 'notification-a' -RecoveryTicketId 'ticket-a')
$script:StartedPopupIds = @()
function Start-NotifyBrokerExactWorker {
  param(
    [string]$PopupId,
    [string]$Mode,
    [string]$NotificationId,
    [string]$SnapshotId = '',
    [string]$RecoveryTicketId = '')
  $script:StartedPopupIds += $PopupId
  return $true
}
Start-NotifyBrokerNextDeferredActivation
Start-NotifyBrokerNextDeferredActivation
if ($script:StartedPopupIds.Count -ne 1 -or
    $script:StartedPopupIds[0] -ne 'popup-a' -or
    $script:NotifyBrokerDeferredActivations.Count -ne 0) {
  throw 'deferred activation did not start exactly once'
}
'PASS broker-deferred-activation-queue'
`;
    const result = spawnSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", harness],
      {
        encoding: "utf8",
        timeout: 15_000,
        env: {
          ...process.env,
          PI_NOTIFY_BROKER_TEST_PATH: brokerPath,
        },
      },
    );
    assert.equal(
      result.status,
      0,
      `broker deferred activation regression failed:\n${result.stdout}\n${result.stderr}`,
    );
    assert.match(result.stdout, /PASS broker-deferred-activation-queue/);
  },
);

test(
  "PowerShell recovery client remains opaque and activates the resolved snapshot",
  { skip: process.platform !== "win32" },
  () => {
    const scriptPath = fileURLToPath(
      new URL("test-route-recovery.ps1", windowsRoot),
    );
    const result = spawnSync(
      "powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        scriptPath,
      ],
      { encoding: "utf8", timeout: 15_000 },
    );
    assert.equal(
      result.status,
      0,
      `PowerShell recovery regression failed:\n${result.stdout}\n${result.stderr}`,
    );
    assert.match(result.stdout, /PASS route-recovery requests=4/);
  },
);
