# Live-state behavior tests: isolated files, fake windows, actual UI callbacks.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
public static class PiNotifyBrokerUser32 {
    public static bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags) { return true; }
}
public static class PiNotifyPopupUser32 {
    public static bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags) { return true; }
}
'@
$script:StatePasses = 0
function Assert-State {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:StatePasses += 1
    Write-Output "PASS $Name"
}
function Read-StateAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
function Get-StateFunctions {
    param($Ast, [string[]]$Names)
    return (($Names | ForEach-Object {
        $name = $_
        $node = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true)
        if ($null -eq $node) { throw "Missing function $name" }
        $node.Extent.Text
    }) -join "`n")
}
function Get-StateShownCallback {
    param($Ast)
    $node = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $a.Member.Value -eq 'Add_Shown' }, $true)
    return $node.Arguments[0].ScriptBlock.GetScriptBlock()
}
$commonAst = Read-StateAst 'NotifyBridge.Common.ps1'
$brokerAst = Read-StateAst 'pi-notify-broker.ps1'
$popupAst = Read-StateAst 'pi-notify-popup.ps1'
$activationAst = Read-StateAst 'NotifyBridge.Activation.ps1'
. ([scriptblock]::Create((Get-StateFunctions $commonAst @('Read-NotifyPopupLiveJson', 'Write-NotifyPopupLiveJson'))))
. ([scriptblock]::Create((Get-StateFunctions $activationAst @('Get-NotifyActivationRemainingMs', 'Get-NotifyPiWebActivationWatchdogMs'))))
. ([scriptblock]::Create((Get-StateFunctions $brokerAst @('Get-NotifyBrokerContextFingerprint', 'Get-NotifyBrokerLiveStatePath', 'Save-NotifyBrokerLiveState', 'Remove-NotifyBrokerLiveState', 'Get-NotifyBrokerRecoveryUiText', 'Reset-NotifyBrokerPopupFeedbackVisuals', 'Set-NotifyBrokerRecoveryUiState', 'Set-NotifyBrokerPopupActivating', 'Complete-NotifyBrokerPopupLifecycle'))))
. ([scriptblock]::Create((Get-StateFunctions $popupAst @('Get-NotifyPopupContextFingerprint', 'Get-NotifyPopupLiveStatePath', 'Save-NotifyPopupLiveState', 'Remove-NotifyPopupLiveState', 'Get-NotifyPopupRecoveryUiText', 'Reset-NotifyPopupFeedbackVisuals', 'Set-NotifyPopupRecoveryUiState', 'Set-NotifyPopupActivating', 'Complete-NotifyPopupLifecycle'))))
$brokerShown = Get-StateShownCallback $brokerAst
$popupShown = Get-StateShownCallback $popupAst
function Write-NotifyBrokerLog { param($Message) }
function Write-NotifyPopupLog { param($Message) }
function Get-NotifyBridgeLogDir { return $script:StateDirectory }
function Start-NotifyBrokerExactWorker { param($PopupId, $Mode, $NotificationId, $RecoveryTicketId) return $true }
function Start-NotifyPopupExactWorker { param($Mode) return $true }
foreach ($surfacePrefix in @('NotifyBroker', 'NotifyPopup')) {
    Set-Variable -Scope Script -Name ($surfacePrefix + 'FailureCloseDelayMs') -Value 2500
    Set-Variable -Scope Script -Name ($surfacePrefix + 'RecoveringActivationWatchdogMs') -Value 12000
    Set-Variable -Scope Script -Name ($surfacePrefix + 'ReadyActivationWatchdogMs') -Value 20000
    Set-Variable -Scope Script -Name ($surfacePrefix + 'HwndTopMost') -Value ([IntPtr](-1))
    Set-Variable -Scope Script -Name ($surfacePrefix + 'SwpShowNoActivate') -Value ([uint32]80)
}
function New-StateCard {
    $form = [pscustomobject]@{
        IsDisposed = $false; Disposing = $false; Tag = $null
        Handle = [IntPtr]::Zero; Left = 0; Top = 0; Width = 420; Height = 154
        Cursor = [System.Windows.Forms.Cursors]::Hand; Opacity = 0.98; BackColor = [System.Drawing.Color]::Black
    }
    $form | Add-Member ScriptMethod Invalidate { param($children) }
    $form | Add-Member ScriptMethod Refresh {}
    $form | Add-Member ScriptMethod Close { $this.IsDisposed = $true }
    $created = [DateTime]::UtcNow.AddSeconds(-10)
    $card = @{
        Form = $form; PopupId = [Guid]::NewGuid().ToString('N'); HasShown = $false
        TargetFingerprint = 'target'; StackIndex = 1; PopupPlacement = 'cursor'
        CreatedAtUtc = $created; ExpiresAtUtc = $created.AddMinutes(1)
        OriginKind = 'terminal'; SnapshotId = 'snapshot'; NotificationId = 'notification'; RecoveryTicketId = ''
        RecoveryState = 'ready'; OriginalAppText = 'Pi'; OriginalSessionText = 'session'; OriginalTitle = 'title'; OriginalBody = 'body'; OriginalCloseText = 'x'
        OriginalOpacity = 0.98; OriginalCardColor = [System.Drawing.Color]::Black; OriginalPanelColor = [System.Drawing.Color]::Black
        TerminalState = [ref]$false; CloseRequested = [ref]$false; Activating = [ref]$false
        DidActivate = [ref]$false; ShouldActivate = [ref]$false; ActivationQueued = [ref]$false
        TerminalOutcome = ''; TerminalReason = ''
    }
    foreach ($name in @('Panel', 'AppLabel', 'SessionLabel', 'TitleLabel', 'BodyLabel', 'CloseLabel')) {
        $card[$name] = New-Object System.Windows.Forms.Label
    }
    foreach ($name in @('App', 'Session', 'Title', 'Body', 'Close')) { $card['Original' + $name + 'ForeColor'] = [System.Drawing.Color]::White }
    foreach ($name in @('Timer', 'FocusWatchTimer', 'FailureCloseTimer', 'ActivationWatchdogTimer', 'SignalTimer')) {
        $card[$name] = New-Object System.Windows.Forms.Timer
    }
    $form.Tag = $card
    return $card
}
function Set-StateFallback {
    param($Card)
    foreach ($key in $Card.Keys) {
        $value = $Card[$key]
        if ($value -is [System.Management.Automation.PSReference]) { $value = $value.Value }
        Set-Variable -Scope Script -Name ('NotifyPopup' + $key) -Value $value
    }
    $script:NotifyPopupTargetOriginKind = $Card.OriginKind
    $script:NotifyPopupTargetSnapshotId = $Card.SnapshotId
    $script:NotifyPopupActivationEvent = [object]::new()
    $script:NotifyPopupActivationKey = 'a' * 32
}
function Save-StateCard {
    param([string]$Surface, $Card)
    if ($Surface -eq 'broker') { Save-NotifyBrokerLiveState -Tag $Card }
    else { Save-NotifyPopupLiveState }
}
function Remove-StateCard {
    param($Card)
    foreach ($value in $Card.Values) { if ($value -is [System.IDisposable]) { $value.Dispose() } }
    Remove-NotifyBrokerLiveState -PopupId $Card.PopupId
    Remove-NotifyPopupLiveState
}
$script:StateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-state-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:StateDirectory)
$config = [pscustomobject]@{ ConfigPath = Join-Path $script:StateDirectory 'config.json' }
$StackIndex = 1; $x = 0; $y = 0; $slot = 1; $PopupPlacement = 'cursor'
try {
    foreach ($surface in @('broker', 'fallback')) {
        $card = New-StateCard
        try {
            if ($surface -eq 'fallback') { Set-StateFallback $card }
            $path = if ($surface -eq 'broker') { Get-NotifyBrokerLiveStatePath $card.PopupId } else { Get-NotifyPopupLiveStatePath }
            Save-StateCard $surface $card
            Assert-State (-not (Test-Path $path)) "$surface initialization does not publish"
            $this = $card.Form; $form = $card.Form; $timer = $card.Timer; $focusWatchTimer = $card.FocusWatchTimer
            if ($surface -eq 'broker') { & $brokerShown } else { & $popupShown }
            Assert-State (Test-Path $path) "$surface Shown publishes ready card"
            $initial = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            Assert-State ([int64]$initial.startedAtTicks -eq $card.CreatedAtUtc.Ticks -and [int64]$initial.expiresAtTicks -eq $card.ExpiresAtUtc.Ticks) "$surface live-state matches original lifetime"
            Save-StateCard $surface $card
            Assert-State (@(Get-ChildItem $script:StateDirectory -Filter '*.tmp-*').Count -eq 0) "$surface atomic replacement leaves no temporary files"
            $accepted = if ($surface -eq 'broker') { Set-NotifyBrokerPopupActivating -Tag $card } else { Set-NotifyPopupActivating }
            Assert-State $accepted "$surface activation starts"
            Assert-State (-not (Test-Path $path)) "$surface activation withdraws hotkey state"
            Save-StateCard $surface $card
            Assert-State (-not (Test-Path $path)) "$surface active card cannot republish"
            if ($surface -eq 'broker') { [void](Complete-NotifyBrokerPopupLifecycle -Tag $card -Outcome failed -Reason retry -Retryable $true) }
            else { [void](Complete-NotifyPopupLifecycle -Outcome failed -Reason retry -Retryable $true) }
            Assert-State (Test-Path $path) "$surface retry restores hotkey state"
            $retry = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            Assert-State ($retry.startedAtTicks -eq $initial.startedAtTicks -and $retry.createdAtUtc -eq $initial.createdAtUtc -and $retry.expiresAtTicks -eq $initial.expiresAtTicks) "$surface retry preserves order and expiry"
            if ($surface -eq 'broker') { [void](Complete-NotifyBrokerPopupLifecycle -Tag $card -Outcome failed -Reason invalid -Retryable $false) }
            else { [void](Complete-NotifyPopupLifecycle -Outcome failed -Reason invalid -Retryable $false) }
            Assert-State (-not (Test-Path $path)) "$surface unavailable state stays out of hotkeys"
        }
        finally { Remove-StateCard $card }

        foreach ($scenario in @('recovering', 'unavailable', 'unavailable-paseo', 'expired', 'closing', 'disposed', 'terminal')) {
            $card = New-StateCard
            try {
                $card.HasShown = $true
                switch ($scenario) {
                    'recovering' { $card.RecoveryState = 'recovering'; $card.OriginKind = 'pi-web'; $card.SnapshotId = ''; $card.RecoveryTicketId = 'recovery-ticket' }
                    'unavailable' { $card.RecoveryState = 'unavailable'; $card.OriginKind = 'pi-web'; $card.SnapshotId = '' }
                    'unavailable-paseo' { $card.RecoveryState = 'unavailable'; $card.OriginKind = 'paseo'; $card.SnapshotId = '' }
                    'expired' { $card.ExpiresAtUtc = [DateTime]::UtcNow.AddSeconds(-1) }
                    'closing' { $card.CloseRequested.Value = $true }
                    'disposed' { $card.Form.IsDisposed = $true }
                    'terminal' { $card.TerminalState.Value = $true }
                }
                if ($surface -eq 'fallback') { Set-StateFallback $card }
                $path = if ($surface -eq 'broker') { Get-NotifyBrokerLiveStatePath $card.PopupId } else { Get-NotifyPopupLiveStatePath }
                if ($scenario -in @('recovering', 'unavailable', 'unavailable-paseo')) {
                    $card.HasShown = $false
                    if ($surface -eq 'fallback') { $script:NotifyPopupHasShown = $false }
                    $this = $card.Form; $form = $card.Form; $timer = $card.Timer; $focusWatchTimer = $card.FocusWatchTimer
                    if ($surface -eq 'broker') { & $brokerShown } else { & $popupShown }
                }
                else { Save-StateCard $surface $card }
                Assert-State ((Test-Path $path) -eq ($scenario -eq 'recovering')) "$surface $scenario hotkey eligibility"
            }
            finally { Remove-StateCard $card }
        }
    }

    $card = New-StateCard
    try {
        $card.HasShown = $true
        Set-StateFallback $card
        $script:NotifyPopupActivationEvent = $null
        Save-NotifyPopupLiveState
        Assert-State (-not (Test-Path (Get-NotifyPopupLiveStatePath))) 'fallback without signal cannot publish a dead hotkey target'
    }
    finally { Remove-StateCard $card }

    $atomicPath = Join-Path $script:StateDirectory 'atomic.json'
    Write-NotifyPopupLiveJson -Path $atomicPath -Payload @{ generation = 1; body = 'first' }
    Write-NotifyPopupLiveJson -Path $atomicPath -Payload @{ generation = 2; body = ('R&D ' * 4096) }
    $atomic = [System.IO.File]::ReadAllText($atomicPath) | ConvertFrom-Json
    Assert-State ($atomic.generation -eq 2 -and $atomic.body.Length -eq 16384) 'atomic write creates and replaces complete JSON'
    $locked = [System.IO.File]::Open($atomicPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $failed = $false
    try {
        try { Write-NotifyPopupLiveJson -Path $atomicPath -Payload @{ generation = 3 } }
        catch { $failed = $true }
    }
    finally { $locked.Dispose() }
    Assert-State $failed 'locked destination rejects atomic replacement'
    Assert-State (([System.IO.File]::ReadAllText($atomicPath) | ConvertFrom-Json).generation -eq 2) 'failed replacement preserves prior JSON'
    Assert-State (@(Get-ChildItem $script:StateDirectory -Filter '*.tmp-*').Count -eq 0) 'failed atomic replacement cleans temporary files'

    # Hold the exact read handle used by production while the UI replaces/removes state.
    $readFunction = $commonAst.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-NotifyPopupLiveJson' }, $true)
    $openExpression = $readFunction.Find({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $a.Member.Value -eq 'Open' }, $true)
    $Path = $atomicPath
    $heldRead = & ([scriptblock]::Create($openExpression.Extent.Text))
    try {
        Write-NotifyPopupLiveJson -Path $atomicPath -Payload @{ generation = 4 }
        Assert-State ((Read-NotifyPopupLiveJson -Path $atomicPath).generation -eq 4) 'hotkey read handle permits atomic replacement'
        [System.IO.File]::Delete($atomicPath)
        Assert-State (-not [System.IO.File]::Exists($atomicPath)) 'hotkey read handle permits immediate withdrawal'
        $oldReader = [System.IO.StreamReader]::new($heldRead, [System.Text.Encoding]::UTF8)
        try { $oldGeneration = ($oldReader.ReadToEnd() | ConvertFrom-Json).generation }
        finally { $oldReader.Dispose() }
        Assert-State ($oldGeneration -eq 2) 'reader retains a complete prior generation during replacement'
    }
    finally { $heldRead.Dispose() }
}
finally {
    Remove-Item -LiteralPath $script:StateDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ("Popup state checks passed: {0}" -f $script:StatePasses)
