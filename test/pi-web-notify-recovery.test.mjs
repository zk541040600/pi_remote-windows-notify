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
  assert.match(popupClick, /\$timer\.Stop\(\)/);
  assert.match(popupClick, /\$focusWatchTimer\.Stop\(\)/);
  assert.match(activate, /protectedRecoveryTicketId/);
  assert.match(activate, /Invoke-NotifyExactRouteRecoveryAndActivate/);

  const exactRouteBlock = activate.slice(
    activate.indexOf("if ($originKind -eq 'pi-web')"),
    activate.indexOf("$requiredText ="),
  );
  assert.doesNotMatch(exactRouteBlock, /activate-route-downgrade/);
  assert.match(
    exactRouteBlock,
    /activate-route-fail-closed[\s\S]*exit 1/,
    "a transient exact-route recovery result must not fall through to Terminal focus",
  );
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
