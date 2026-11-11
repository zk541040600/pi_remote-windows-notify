# Exercise actual scheduling functions with isolated cards, without desktop activation.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0
function Assert-Coordination {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}
function Read-CoordinationAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
function Get-CoordinationFunctions {
    param($Ast, [string[]]$Names)
    $parts = foreach ($name in $Names) {
        $found = $Ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $found) { throw "Function missing: $name" }
        $found.Extent.Text
    }
    return ($parts -join "`n")
}
$brokerAst = Read-CoordinationAst 'pi-notify-broker.ps1'
function Write-NotifyBrokerLog { param($Message) }
. ([scriptblock]::Create((Get-CoordinationFunctions $brokerAst @('Get-NotifyBrokerPopupSlot'))))

# A failed eviction must not sacrifice a second, unrelated card.
foreach ($closeFails in @($true, $false)) {
    $script:ClosedIds = [System.Collections.Generic.List[string]]::new()
    $script:EvictionFails = $closeFails
    $script:NotifyBrokerActivePopups = @{}
    foreach ($id in @('oldest', 'newer')) {
        $tag = @{ PopupId = $id; TerminalState = [ref]$false }
        $script:NotifyBrokerActivePopups[$id] = [pscustomobject]@{
            PopupId = $id; TargetFingerprint = $id; StackIndex = $script:NotifyBrokerActivePopups.Count
            CreatedAtUtc = [DateTime]::UtcNow.AddSeconds($(if ($id -eq 'oldest') { -2 } else { -1 }))
            Form = [pscustomobject]@{ Tag = $tag }
        }
    }
    function Complete-NotifyBrokerPopupLifecycle {
        param($Tag, $Outcome, $Reason)
        $script:ClosedIds.Add([string]$Tag.PopupId)
        if ($script:EvictionFails -and $Tag.PopupId -eq 'oldest') { return $false }
        $script:NotifyBrokerActivePopups.Remove([string]$Tag.PopupId)
        return $true
    }
    $slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'incoming' -MaxVisible 2
    Assert-Coordination ($slot -eq $(if ($closeFails) { -1 } else { 0 })) "overflow allocation respects eviction result failure=$closeFails"
    Assert-Coordination ($script:ClosedIds.Count -eq 1 -and $script:ClosedIds[0] -eq 'oldest') "overflow attempts only the oldest card failure=$closeFails"
    Assert-Coordination ($script:NotifyBrokerActivePopups.ContainsKey('newer')) "overflow preserves unrelated newer card failure=$closeFails"
}

$popupAst = Read-CoordinationAst 'pi-notify-popup.ps1'
$activationAst = Read-CoordinationAst 'NotifyBridge.Activation.ps1'
# Extracted functions have no source-file root; bind only their file lookup base.
$script:CoordinationSourceRoot = $PSScriptRoot
function Join-Path {
    param([string]$Path, [string]$ChildPath)
    if ([string]::IsNullOrEmpty($Path)) { $Path = $script:CoordinationSourceRoot }
    return [System.IO.Path]::Combine($Path, $ChildPath)
}
. ([scriptblock]::Create((Get-CoordinationFunctions $activationAst @('Get-NotifyActivationRemainingMs'))))
. ([scriptblock]::Create((Get-CoordinationFunctions $brokerAst @('Start-NotifyBrokerExactWorker', 'Start-NotifyBrokerNextDeferredActivation', 'Take-NotifyBrokerDeferredActivation', 'Add-NotifyBrokerDeferredActivation'))))
. ([scriptblock]::Create((Get-CoordinationFunctions $popupAst @('Start-NotifyPopupExactWorker'))))
function Write-NotifyPopupLog { param($Message) }
function Ensure-NotifyBrokerExactWorkerTimer {}
function Set-NotifyBrokerExactWorkerFailClosed { param($PopupId, $Reason, $Operation, $OriginKind) throw "Unexpected worker failure: $Reason ($($Error[0]))" }
function Get-NotifyActivationWorkerScript { $script:WorkerStarts += 1; return 'param($Operation) "isolated worker"' }
function Complete-NotifyBrokerPopupLifecycle {
    param($Tag, $Outcome, $Reason)
    $script:Dismissals.Add([string]$Tag.PopupId + '/' + $Reason)
    $script:NotifyBrokerActivePopups.Remove([string]$Tag.PopupId)
    return $true
}
function Complete-NotifyPopupLifecycle {
    param($Outcome, $Reason)
    $script:Dismissals.Add('fallback/' + $Reason)
    return $true
}
function New-CoordinationCard {
    param([string]$Id = 'card', [string]$Scenario = 'ready')
    $tag = @{
        PopupId = $Id; OriginKind = 'paseo'; TerminalState = [ref]($Scenario -eq 'terminal')
        CloseRequested = [ref]($Scenario -eq 'closing')
        ExpiresAtUtc = [DateTime]::UtcNow.AddSeconds($(if ($Scenario -eq 'expired') { -1 } else { 60 }))
    }
    $form = [pscustomobject]@{ Tag = $tag; IsDisposed = ($Scenario -eq 'disposed'); Disposing = ($Scenario -eq 'disposing') }
    $tag.Form = $form
    return [pscustomobject]@{ Form = $form }
}
$fakeTimer = [pscustomobject]@{}
$fakeTimer | Add-Member ScriptMethod Start {}
$script:NotifyBrokerExactWorkerTimer = $fakeTimer
$script:NotifyPopupExactWorkerTimer = $fakeTimer
$script:NotifyBrokerExactWorkerMax = 32
$script:NotifyBrokerDeferredActivationMax = 32
$script:NotifyBrokerDeferredActivationSequence = 0
$script:NotifyBrokerExactWorkerSequence = 0
$script:NotifyBrokerActivationRecoveryWaitMs = 10000
$script:NotifyPopupActivationRecoveryWaitMs = 10000
$ConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) 'isolated-popup-config.json'
foreach ($surface in @('broker', 'fallback')) {
    foreach ($scenario in @('expired', 'closing', 'disposed', 'disposing', 'terminal', 'ready')) {
        $script:WorkerStarts = 0
        $script:Dismissals = [System.Collections.Generic.List[string]]::new()
        $card = New-CoordinationCard -Scenario $scenario
        $script:NotifyBrokerActivePopups = @{ card = $card }
        $script:NotifyBrokerExactWorkers = @{}
        $script:NotifyBrokerDeferredActivations = @{}
        $script:NotifyPopupExactWorker = $null
        $script:NotifyPopupForm = $card.Form
        $script:NotifyPopupTerminalState = $card.Form.Tag.TerminalState.Value
        $script:NotifyPopupCloseRequested = $card.Form.Tag.CloseRequested.Value
        $script:NotifyPopupExpiresAtUtc = $card.Form.Tag.ExpiresAtUtc
        foreach ($name in @('NotificationId', 'SnapshotId', 'RecoveryTicketId', 'Host', 'CwdBase', 'SourceTabTitle', 'Fingerprint')) {
            Set-Variable -Scope Script -Name ('NotifyPopupTarget' + $name) -Value ''
        }
        $script:NotifyPopupTargetOriginKind = 'paseo'
        try {
            $accepted = if ($surface -eq 'broker') { Start-NotifyBrokerExactWorker -PopupId 'card' -Mode activate -OriginKind paseo }
                else { Start-NotifyPopupExactWorker -Mode activate -OriginKind paseo }
            Assert-Coordination ($accepted -eq ($scenario -eq 'ready')) "$surface worker admission $scenario"
            Assert-Coordination ($script:WorkerStarts -eq $(if ($scenario -eq 'ready') { 1 } else { 0 })) "$surface does not create stale workers $scenario"
            if ($scenario -eq 'expired') { Assert-Coordination ($script:Dismissals.Count -eq 1 -and $script:Dismissals[0].EndsWith('/expired')) "$surface dismisses expired work at admission" }
        }
        finally {
            $workers = @($script:NotifyBrokerExactWorkers.Values) + @($script:NotifyPopupExactWorker)
            foreach ($worker in $workers) {
                if ($null -eq $worker) { continue }
                try { [void]$worker.PowerShell.EndInvoke($worker.Async) }
                finally { $worker.PowerShell.Dispose(); $worker.Runspace.Close(); $worker.Runspace.Dispose() }
            }
        }
    }
}

# A stale intent cannot starve the next live intent when the final slot is reclaimed.
$script:NotifyBrokerExactWorkers = @{}
$script:NotifyBrokerDeferredActivations = @{}
$script:NotifyBrokerActivePopups = @{ expired = (New-CoordinationCard -Id 'expired' -Scenario expired); live = (New-CoordinationCard -Id 'live') }
$script:Dismissals.Clear()
$script:WorkerStarts = 0
[void](Add-NotifyBrokerDeferredActivation -PopupId expired -NotificationId n1)
[void](Add-NotifyBrokerDeferredActivation -PopupId live -NotificationId n2)
try {
    Start-NotifyBrokerNextDeferredActivation
    Assert-Coordination ($script:NotifyBrokerDeferredActivations.Count -eq 0) 'deferred scheduler advances past expired work'
    Assert-Coordination ($script:NotifyBrokerExactWorkers.Count -eq 1 -and @($script:NotifyBrokerExactWorkers.Values)[0].PopupId -eq 'live') 'only the live deferred card starts'
    Assert-Coordination ($script:Dismissals.Contains('expired/expired')) 'expired deferred card is dismissed'
}
finally {
    foreach ($worker in @($script:NotifyBrokerExactWorkers.Values)) {
        try { [void]$worker.PowerShell.EndInvoke($worker.Async) }
        finally { $worker.PowerShell.Dispose(); $worker.Runspace.Close(); $worker.Runspace.Dispose() }
    }
}

Write-Output "Popup coordination tests passed: $script:PassCount"
