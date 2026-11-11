# Execute popup functions and callbacks without displaying UI or activating real sessions.
# Windows PowerShell 5.1: powershell.exe -NoProfile -STA -File windows/test-popup-ui.ps1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:PassCount = 0
$script:NotifyBrokerActivePopups = @{}

function Assert-Ui {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}

function Read-TestAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}

function Get-TestFunctions {
    param($Ast, [string[]]$Names)
    $parts = foreach ($name in $Names) {
        $found = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true)
        if ($null -eq $found) { throw "Function missing: $name" }
        $found.Extent.Text
    }
    return ($parts -join "`n")
}

$brokerAst = Read-TestAst 'pi-notify-broker.ps1'
$popupAst = Read-TestAst 'pi-notify-popup.ps1'
$activationAst = Read-TestAst 'NotifyBridge.Activation.ps1'
. ([scriptblock]::Create((Get-TestFunctions $activationAst @('Get-NotifyActivationRemainingMs', 'Get-NotifyPiWebActivationWatchdogMs'))))
. ([scriptblock]::Create((Get-TestFunctions $brokerAst @('Get-NotifyBrokerRecoveryUiText', 'Set-NotifyBrokerPopupActivating'))))
. ([scriptblock]::Create((Get-TestFunctions $popupAst @('Get-NotifyPopupRecoveryUiText', 'Set-NotifyPopupActivating', 'Get-NotifyPopupContextFingerprint'))))

function Write-NotifyBrokerLog { param($Message) }
function Write-NotifyPopupLog { param($Message) }
function Complete-NotifyBrokerPopupLifecycle {
    param($Tag, $Outcome, $Reason)
    $Tag.TerminalState.Value = $true
    $Tag.CloseRequested.Value = $true
    if ($Tag.ContainsKey('PopupId')) { $script:NotifyBrokerActivePopups.Remove([string]$Tag.PopupId) }
    $script:DismissReason = $Reason
    return $true
}
function Complete-NotifyPopupLifecycle {
    param($Outcome, $Reason)
    $script:NotifyPopupTerminalState = $true
    $script:NotifyPopupCloseRequested = $true
    $script:DismissReason = $Reason
    return $true
}

function New-TestCard {
    # A fake form can close during Refresh; labels/timers are actual WinForms controls.
    $form = [pscustomobject]@{
        IsDisposed = $false; Disposing = $false; CloseOnRefresh = $false
        Cursor = [System.Windows.Forms.Cursors]::Hand
        Opacity = 0.98; BackColor = [System.Drawing.Color]::Black
    }
    $form | Add-Member ScriptMethod Invalidate { param($children) }
    $form | Add-Member ScriptMethod Refresh { if ($this.CloseOnRefresh) { $this.IsDisposed = $true } }
    $card = @{
        PopupId = 'test'; Form = $form; OriginKind = 'pi-web'; SnapshotId = 'test-snapshot'
        OriginalAppText = 'Pi'; OriginalSessionText = 'session R&D'; OriginalBody = 'body'
        DidActivate = [ref]$false; ShouldActivate = [ref]$false; ActivationQueued = [ref]$false
        ExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(1)
        TerminalState = [ref]$false; CloseRequested = [ref]$false; Activating = [ref]$false
    }
    foreach ($name in @('Panel', 'AppLabel', 'SessionLabel', 'TitleLabel', 'BodyLabel')) {
        $card[$name] = New-Object System.Windows.Forms.Label
    }
    foreach ($name in @('Timer', 'FocusWatchTimer', 'ActivationWatchdogTimer', 'FailureCloseTimer')) {
        $card[$name] = New-Object System.Windows.Forms.Timer
    }
    $card.SessionLabel.Text = $card.OriginalSessionText
    return $card
}

function Remove-TestCard {
    param($Card)
    foreach ($name in @('Panel', 'AppLabel', 'SessionLabel', 'TitleLabel', 'BodyLabel', 'Timer', 'FocusWatchTimer', 'ActivationWatchdogTimer', 'FailureCloseTimer')) {
        $Card[$name].Dispose()
    }
}

function Set-TestFallbackState {
    param($Card)
    foreach ($name in @('Form', 'Panel', 'AppLabel', 'SessionLabel', 'TitleLabel', 'BodyLabel', 'Timer', 'FocusWatchTimer', 'ActivationWatchdogTimer', 'FailureCloseTimer', 'OriginalAppText', 'OriginalSessionText', 'OriginalBody', 'ExpiresAtUtc')) {
        Set-Variable -Scope Script -Name ('NotifyPopup' + $name) -Value $Card[$name]
    }
    $script:NotifyPopupTargetOriginKind = $Card.OriginKind
    $script:NotifyPopupTargetSnapshotId = $Card.SnapshotId
    $script:NotifyPopupTerminalState = $Card.TerminalState.Value
    $script:NotifyPopupCloseRequested = $Card.CloseRequested.Value
    $script:NotifyPopupActivating = $Card.Activating.Value
}

foreach ($surface in @('broker', 'fallback')) {
    foreach ($scenario in @('ready', 'disposed', 'closing', 'terminal', 'expired', 'refresh-closes')) {
        $card = New-TestCard
        $script:DismissReason = ''
        try {
            switch ($scenario) {
                'disposed' { $card.Form.IsDisposed = $true }
                'closing' { $card.CloseRequested.Value = $true }
                'terminal' { $card.TerminalState.Value = $true }
                'expired' { $card.ExpiresAtUtc = [DateTime]::UtcNow.AddSeconds(-1) }
                'refresh-closes' { $card.Form.CloseOnRefresh = $true }
            }
            if ($surface -eq 'broker') { $accepted = Set-NotifyBrokerPopupActivating -Tag $card }
            else {
                Set-TestFallbackState $card
                $accepted = Set-NotifyPopupActivating
            }
            Assert-Ui ($accepted -eq ($scenario -eq 'ready')) "$surface activation $scenario"
            if ($scenario -eq 'expired') { Assert-Ui ($script:DismissReason -eq 'expired') "$surface expires before activation" }
            if ($scenario -eq 'ready') {
                Assert-Ui ($card.SessionLabel.Text -ceq 'session R&D') "$surface keeps session name"
                if ($surface -eq 'broker') { $again = Set-NotifyBrokerPopupActivating -Tag $card }
                else { $again = Set-NotifyPopupActivating }
                Assert-Ui (-not $again) "$surface ignores duplicate activation"
            }
        }
        finally { Remove-TestCard $card }
    }
}


# Activation for every source is bounded by the same original popup deadline.
$script:NotifyBrokerRecoveringActivationWatchdogMs = 12000
$script:NotifyBrokerReadyActivationWatchdogMs = 20000
$script:NotifyPopupRecoveringActivationWatchdogMs = 12000
$script:NotifyPopupReadyActivationWatchdogMs = 20000
foreach ($surface in @('broker', 'fallback')) {
    foreach ($origin in @('terminal', '', 'paseo', 'pi-web')) {
        foreach ($snapshot in @('', 'ready-snapshot')) {
            $card = New-TestCard
            try {
                $card.OriginKind = $origin
                $card.SnapshotId = $snapshot
                $card.ExpiresAtUtc = [DateTime]::UtcNow.AddSeconds(2)
                $deadline = $card.ExpiresAtUtc
                if ($surface -eq 'broker') { $accepted = Set-NotifyBrokerPopupActivating -Tag $card }
                else { Set-TestFallbackState $card; $accepted = Set-NotifyPopupActivating }
                Assert-Ui $accepted "$surface $origin activation accepted near expiry snapshot=$snapshot"
                Assert-Ui ($card.ActivationWatchdogTimer.Interval -gt 0 -and $card.ActivationWatchdogTimer.Interval -le 2000) "$surface $origin watchdog stays within remaining life snapshot=$snapshot"
                Assert-Ui ($card.ExpiresAtUtc -eq $deadline) "$surface $origin preserves deadline snapshot=$snapshot"
            }
            finally { Remove-TestCard $card }
        }
    }
}

# Each request selects its own screen, independent of the broker's startup setting.
$commonAst = Read-TestAst 'NotifyBridge.Common.ps1'
. ([scriptblock]::Create((Get-TestFunctions $commonAst @('Normalize-NotifyBridgePopupPlacement', 'Get-NotifyPopupStackCapacity', 'Get-NotifyPopupStackPosition'))))
. ([scriptblock]::Create((Get-TestFunctions $brokerAst @('Get-NotifyBrokerPopupLocation'))))
function Get-NotifyBrokerWorkingArea {
    param([string]$Placement)
    $script:SeenPlacement = $Placement
    switch ($Placement) {
        'right' { return [System.Drawing.Rectangle]::new(1920, 0, 1920, 1040) }
        'primary' { return [System.Drawing.Rectangle]::new(0, 0, 1920, 1040) }
        default { return [System.Drawing.Rectangle]::new(-1280, -100, 1280, 800) }
    }
}
$PopupPlacement = 'primary'
foreach ($placement in @('cursor', 'right', 'primary')) {
    $position = Get-NotifyBrokerPopupLocation -StackIndex 0 -FormWidth 420 -FormHeight 154 -Placement $placement
    Assert-Ui ($script:SeenPlacement -eq $placement) "placement $placement passed to screen selection"
    $area = Get-NotifyBrokerWorkingArea -Placement $placement
    Assert-Ui ($area.Contains([System.Drawing.Rectangle]::new($position.X, $position.Y, 420, 154))) "placement $placement stays on requested screen"
}
$null = Get-NotifyBrokerPopupLocation -StackIndex 0 -FormWidth 420 -FormHeight 154 -Placement ' RIGHT '
Assert-Ui ($script:SeenPlacement -eq 'right') 'placement normalized'
$null = Get-NotifyBrokerPopupLocation -StackIndex 0 -FormWidth 420 -FormHeight 154 -Placement 'invalid'
Assert-Ui ($script:SeenPlacement -eq 'cursor') 'invalid placement uses cursor'


# Capacity and coordinates use the same geometry on both display paths.
foreach ($height in @(480, 500, 600, 720, 1040)) {
    foreach ($cardHeight in @(154, 231)) {
        $area = [System.Drawing.Rectangle]::new(-1280, -120, 1280, $height)
        $capacity = Get-NotifyPopupStackCapacity -WorkingAreaHeight $height -FormHeight $cardHeight -MaxVisible 8
        $rectangles = @()
        for ($slot = 0; $slot -lt $capacity; $slot++) {
            $position = Get-NotifyPopupStackPosition -WorkingArea $area -StackIndex $slot -FormWidth 420 -FormHeight $cardHeight
            $rect = [System.Drawing.Rectangle]::new($position.X, $position.Y, 420, $cardHeight)
            Assert-Ui ($area.Contains($rect)) "layout height=$height card=$cardHeight slot=$slot inside work area"
            foreach ($previous in $rectangles) {
                Assert-Ui (-not $rect.IntersectsWith($previous)) "layout height=$height card=$cardHeight slot=$slot no overlap"
            }
            $rectangles += $rect
        }
    }
}

. ([scriptblock]::Create((Get-TestFunctions $brokerAst @('Get-NotifyBrokerPopupSlot'))))
function Add-TestPopupEntry {
    param([string]$Id, [string]$Target, [int]$Slot, [int]$Age)
    $tag = @{ PopupId=$Id; TerminalState=[ref]$false; CloseRequested=[ref]$false }
    $script:NotifyBrokerActivePopups[$Id] = [pscustomobject]@{
        PopupId=$Id; TargetFingerprint=$Target; StackIndex=$Slot
        CreatedAtUtc=[DateTime]::UtcNow.AddSeconds(-$Age)
        Form=[pscustomobject]@{Tag=$tag}
    }
}
$script:NotifyBrokerActivePopups = @{}
Add-TestPopupEntry 'old' 'target-a' 0 30
Add-TestPopupEntry 'middle' 'target-b' 1 20
Add-TestPopupEntry 'new' 'target-c' 2 10
$slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'target-d' -StackIndex 0 -MaxVisible 3
Assert-Ui ($slot -eq 0 -and -not $script:NotifyBrokerActivePopups.ContainsKey('old')) 'full stack retires oldest'
Assert-Ui ($script:NotifyBrokerActivePopups.Count -eq 2) 'full stack preserves other notifications'
$slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'target-c' -MaxVisible 3
Assert-Ui ($slot -eq 2 -and -not $script:NotifyBrokerActivePopups.ContainsKey('new')) 'replacement reuses target slot'
$slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'target-e' -StackIndex 1 -MaxVisible 3
Assert-Ui ($slot -eq 0) 'occupied explicit slot is reassigned'
Add-TestPopupEntry 'offscreen' 'target-z' 7 5
$slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'target-e' -StackIndex 7 -MaxVisible 2
Assert-Ui ($slot -ge 0 -and $slot -lt 2 -and -not $script:NotifyBrokerActivePopups.ContainsKey('offscreen')) 'screen shrink removes out-of-range slot'

# The fallback listener uses the same capacity, and only stops instance-filtered fixtures.
$listenerAst = Read-TestAst 'notify-listener.ps1'
. ([scriptblock]::Create((Get-TestFunctions $listenerAst @('Get-NotifyPopupStackPlan'))))
function Get-NotifyPopupWorkingArea { param($Placement) return [System.Drawing.Rectangle]::new(0, 0, 1280, 500) }
function Get-NotifyPopupProcesses { return $script:TestProcesses }
function Write-NotifyListenerLog { param($Message) }
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
    if ($script:TestStopFails) { throw 'simulated process exit failure' }
    $script:StoppedIds += $Id
}
$config = [pscustomobject]@{ PopupPlacement='cursor'; PopupMaxVisible=4 }
$script:TestStopFails=$false
$script:StoppedIds=@()
$script:TestProcesses=@(
    [pscustomobject]@{ProcessId=101;TargetFingerprint='a';StackIndex=0;CreatedAtUtc=[DateTime]::UtcNow.AddSeconds(-20)}
    [pscustomobject]@{ProcessId=102;TargetFingerprint='b';StackIndex=1;CreatedAtUtc=[DateTime]::UtcNow.AddSeconds(-10)}
)
$slot=Get-NotifyPopupStackPlan -TargetKey 'new' -TargetFingerprint 'c'
Assert-Ui ($slot -eq 0 -and ($script:StoppedIds -join ',') -eq '101') 'fallback overflow retires only oldest'
$script:StoppedIds=@()
$slot=Get-NotifyPopupStackPlan -TargetKey 'new' -TargetFingerprint 'b'
Assert-Ui ($slot -eq 1 -and ($script:StoppedIds -join ',') -eq '102') 'fallback replacement keeps target slot'
$script:TestStopFails=$true
$slot=Get-NotifyPopupStackPlan -TargetKey 'new' -TargetFingerprint 'c'
Assert-Ui ($slot -eq -1) 'fallback refuses overlap if old processes cannot close'


. ([scriptblock]::Create((Get-TestFunctions $commonAst @('Get-NotifyPopupLifetimeMs'))))
foreach ($seconds in @(-1, 0, 3, 1800, 2147483, 2147484, [int]::MaxValue)) {
    $lifetime = Get-NotifyPopupLifetimeMs -TimeoutSeconds $seconds
    $timer = New-Object System.Windows.Forms.Timer
    try {
        $timer.Interval = $lifetime
        Assert-Ui ($lifetime -is [int] -and $timer.Interval -ge 3000) "lifetime $seconds fits native WinForms timer"
        $now = [DateTime]::UtcNow
        $expiry = $now.AddMilliseconds($lifetime)
        Assert-Ui ((Get-NotifyActivationRemainingMs -ExpiresAtUtc $expiry -NowUtc $now) -eq $timer.Interval) "lifetime $seconds matches immutable deadline"
    } finally { $timer.Dispose() }
}
Assert-Ui ((Get-NotifyPopupLifetimeMs 1800) -eq 1800000) 'normal 30-minute lifetime unchanged'
Assert-Ui ((Get-NotifyPopupLifetimeMs ([int]::MaxValue)) -eq [int]::MaxValue) 'oversized lifetime saturates'


# Execute the real queue callback against mocked effects; continuous producers cannot starve UI.
$tickAst = $brokerAst.Find({
    param($a)
    $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $a.Expression.Extent.Text -eq '$script:NotifyBrokerDispatchTimer' -and $a.Member.Value -eq 'Add_Tick'
}, $true)
$dispatch = $tickAst.Arguments[0].ScriptBlock.GetScriptBlock()
$config = [pscustomobject]@{ RemoteHostAlias='test'; PopupTimeoutSeconds=1800 }
$PopupPlacement='cursor'
$script:NotifyBrokerSequenceId=0
$script:NotifyBrokerPopupQueue=[System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:DispatchSeen=[System.Collections.Generic.List[string]]::new()
$script:DispatchErrors=[System.Collections.Generic.List[string]]::new()
$script:ReplenishQueue=$false
function Write-NotifyBrokerLog { param($Message) if ($Message -like 'broker-dispatch-error*') { $script:DispatchErrors.Add($Message) } }
function Get-NotifyBrokerContextFingerprint { param($Value) return 'test-fingerprint' }
function Get-NotifyRouteFingerprint { param($Value) return 'test-fingerprint' }
function Show-NotifyBrokerPopup {
    param($Title)
    $script:DispatchSeen.Add(('popup:' + $Title))
    if ($script:ReplenishQueue) {
        $script:NotifyBrokerPopupQueue.Enqueue([pscustomobject]@{
            Action='/popup'; Body='{"title":"again","body":"body","cwdBase":"test"}'; ReceivedAt=[DateTime]::UtcNow
        })
    }
}
function Close-NotifyBrokerPopup { param($PopupId, $Activate) $script:DispatchSeen.Add(('close:' + $PopupId)) }
function Invoke-NotifyBrokerOldestPopupActivation { $script:DispatchSeen.Add('oldest'); return $true }
$expected=[System.Collections.Generic.List[string]]::new()
for ($i=0; $i -lt 40; $i++) {
    $action='/popup'; $body=(@{title=[string]$i;body='body';cwdBase='test'} | ConvertTo-Json -Compress)
    switch ($i % 3) {
        0 { $expected.Add(('popup:' + $i)) }
        1 { $action='/close'; $body=(@{popupId=[string]$i} | ConvertTo-Json -Compress); $expected.Add(('close:' + $i)) }
        2 { $action='/activate-oldest'; $body='{}'; $expected.Add('oldest') }
    }
    $script:NotifyBrokerPopupQueue.Enqueue([pscustomobject]@{Action=$action;Body=$body;ReceivedAt=[DateTime]::UtcNow})
}
for ($batch=1; $batch -le 5; $batch++) {
    & $dispatch
    Assert-Ui ($script:DispatchSeen.Count -eq ($batch * 8)) "dispatch yields after batch $batch"
}
Assert-Ui (($script:DispatchSeen -join '|') -ceq ($expected -join '|')) 'dispatch preserves FIFO across batches'
Assert-Ui ($script:NotifyBrokerPopupQueue.Count -eq 0 -and $script:DispatchErrors.Count -eq 0) 'dispatch drains valid requests without errors'
$script:DispatchSeen.Clear()
$script:ReplenishQueue=$true
$script:NotifyBrokerPopupQueue.Enqueue([pscustomobject]@{Action='/popup';Body='{"title":"start","body":"body","cwdBase":"test"}';ReceivedAt=[DateTime]::UtcNow})
& $dispatch
Assert-Ui ($script:DispatchSeen.Count -eq 8 -and $script:NotifyBrokerPopupQueue.Count -eq 1) 'continuous enqueue still yields after eight requests'


# A fallback hotkey signals the existing popup; it cannot invent a Terminal route.
$hotkeyAst=Read-TestAst 'pi-notify-hotkey.ps1'
. ([scriptblock]::Create((Get-TestFunctions $commonAst @('Get-NotifyPopupActivationEventName'))))
. ([scriptblock]::Create((Get-TestFunctions $hotkeyAst @('Start-NotifyHotkeyActivation', 'Get-NotifyHotkeyLivePopupStates', 'Get-NotifyHotkeyFingerprint'))))
function Write-NotifyHotkeyLog { param($Message) }
$script:HotkeyOwnsProcess=$true
function Test-NotifyHotkeyPopupProcessOwned { param($ProcessId) return $script:HotkeyOwnsProcess }
$script:StartedOrigins=[System.Collections.Generic.List[string]]::new()
function Start-NotifyPopupPaseoWorker { param($ActivationId) $script:StartedOrigins.Add('paseo'); return $true }
function Start-NotifyPopupExactWorker { param($Mode,$OriginKind) $script:StartedOrigins.Add($OriginKind); return $true }
function Request-NotifyPopupExactWorkerStop { param($Reason) return $true }
$script:PaseoCloseRequested=$false
function Test-NotifyPaseoCloseSignal { param($NotificationId,$CloseEvent) return $script:PaseoCloseRequested }
$clickAst=$popupAst.Find({param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$activateAction'},$true)
$clickBlock=$clickAst.Right.Find({param($a) $a -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$true)
$activateAction=$clickBlock.ScriptBlock.GetScriptBlock()
$signalAst=$popupAst.Find({
    param($a)
    $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $a.Expression.Extent.Text -eq '$script:NotifyPopupSignalTimer' -and $a.Member.Value -eq 'Add_Tick'
},$true)
$signalTick=$signalAst.Arguments[0].ScriptBlock.GetScriptBlock()
$targetHost='test'; $targetCwdBase=''; $targetSourceTabTitle=''; $targetNotificationId='test-notification'
$targetSnapshotId='test-snapshot'; $targetRecoveryTicketId=''
$script:NotifyPopupPaseoCloseEvent=$null
foreach ($origin in @('paseo','pi-web','terminal')) {
    $card=New-TestCard
    $card.OriginKind=$origin
    $card.SnapshotId='test-snapshot'
    $script:NotifyPopupReadyActivationWatchdogMs=20000
    $script:NotifyPopupRecoveringActivationWatchdogMs=12000
    Set-TestFallbackState $card
    $script:NotifyPopupDidActivate=$false
    $script:NotifyPopupRecoveryState='ready'
    $script:NotifyPopupExactWorker=$null
    $script:StartedOrigins.Clear()
    $targetOriginKind=$origin
    $key=[Guid]::NewGuid().ToString('N')
    $name=Get-NotifyPopupActivationEventName -ProcessId $PID -ActivationKey $key
    $script:NotifyPopupActivationEvent=[System.Threading.EventWaitHandle]::new($false,[System.Threading.EventResetMode]::AutoReset,$name)
    $this=New-Object System.Windows.Forms.Timer
    $state=[pscustomobject]@{BrokerManaged=$false;ProcessId=$PID;ActivationKey=$key}
    try {
        Assert-Ui (Start-NotifyHotkeyActivation $state) "hotkey $origin signals live popup without cwd/tab"
        & $signalTick
        Assert-Ui (($script:StartedOrigins -join ',') -eq $origin) "hotkey $origin uses the original click strategy"
        Assert-Ui (Start-NotifyHotkeyActivation $state) "hotkey $origin repeat signal accepted"
        & $signalTick
        Assert-Ui ($script:StartedOrigins.Count -eq 1) "hotkey $origin repeat cannot start a second worker"
        $script:NotifyPopupTerminalState=$true
        $script:NotifyPopupDidActivate=$false
        [void](Start-NotifyHotkeyActivation $state)
        & $signalTick
        Assert-Ui ($script:StartedOrigins.Count -eq 1) "hotkey $origin cannot reactivate closed popup"
    }
    finally {
        $script:NotifyPopupActivationEvent.Dispose()
        $script:NotifyPopupActivationEvent=$null
        $this.Dispose()
        Remove-TestCard $card
    }
    Assert-Ui (-not (Start-NotifyHotkeyActivation $state)) "hotkey $origin closed event fails safely"
}
Assert-Ui ([string]::IsNullOrWhiteSpace((Get-NotifyPopupActivationEventName -ProcessId $PID -ActivationKey '../foreign-event'))) 'hotkey rejects arbitrary event names'
Assert-Ui ([string]::IsNullOrWhiteSpace((Get-NotifyPopupActivationEventName -ProcessId 0 -ActivationKey ('a'*32)))) 'hotkey rejects invalid process ID'

# Exercise selection using temporary state only: no route text or real account configuration.
$script:HotkeyStateDirectory=Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-ui-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:HotkeyStateDirectory | Out-Null
function Get-NotifyBridgeLogDir { return $script:HotkeyStateDirectory }
$config=[pscustomobject]@{ConfigPath=(Join-Path $script:HotkeyStateDirectory 'config.json')}
$statePath=Join-Path $script:HotkeyStateDirectory 'popup-live.test.json'
$diskState=@{
    processId=$PID;activationKey=[Guid]::NewGuid().ToString('N')
    configFingerprint=(Get-NotifyHotkeyFingerprint -Value $config.ConfigPath)
    expiresAtTicks=[DateTime]::UtcNow.AddMinutes(1).Ticks
    startedAtTicks=[DateTime]::UtcNow.Ticks;stackIndex=0;targetFingerprint='test'
}
try {
    [System.IO.File]::WriteAllText($statePath,($diskState|ConvertTo-Json))
    $states=@(Get-NotifyHotkeyLivePopupStates)
    Assert-Ui ($states.Count -eq 1 -and $states[0].ActivationKey -eq $diskState.activationKey) 'fallback selection does not require Terminal metadata'
    $script:HotkeyOwnsProcess=$false
    Assert-Ui (@(Get-NotifyHotkeyLivePopupStates).Count -eq 0) 'fallback selection rejects foreign process'
    $script:HotkeyOwnsProcess=$true
    $diskState.activationKey=''
    [System.IO.File]::WriteAllText($statePath,($diskState|ConvertTo-Json))
    Assert-Ui (@(Get-NotifyHotkeyLivePopupStates).Count -eq 0) 'legacy fallback state cannot guess a route'
} finally {
    Remove-Item -LiteralPath $script:HotkeyStateDirectory -Recurse -Force
}


# A close failure cannot make an occupied slot reusable.
& {
    . ([scriptblock]::Create((Get-TestFunctions $brokerAst @('Get-NotifyBrokerPopupSlot'))))
    function Complete-NotifyBrokerPopupLifecycle { param($Tag,$Outcome,$Reason) return $false }
    $script:NotifyBrokerActivePopups=@{}
    Add-TestPopupEntry 'stuck' 'same' 0 10
    $slot=Get-NotifyBrokerPopupSlot -PopupId 'new' -TargetFingerprint 'same' -MaxVisible 1
    Assert-Ui ($slot -eq -1 -and $script:NotifyBrokerActivePopups.ContainsKey('stuck')) 'same-target close failure never reuses occupied slot'
    $script:NotifyBrokerActivePopups=@{}
    Add-TestPopupEntry 'stuck' 'other' 7 10
    $slot=Get-NotifyBrokerPopupSlot -PopupId 'new' -TargetFingerprint 'new' -MaxVisible 1
    Assert-Ui ($slot -eq -1 -and $script:NotifyBrokerActivePopups.ContainsKey('stuck')) 'screen-overflow close failure stops new placement'
}

# Exercise the real global hotkey entry, including a healthy-but-empty broker.
& {
    . ([scriptblock]::Create((Get-TestFunctions $hotkeyAst @('Invoke-NotifyHotkeyOldestPopup'))))
    function Get-NotifyHotkeyLivePopupStates { return $script:EntryStates }
    function Start-NotifyHotkeyActivation { param($PopupState) $script:EntryAttempts.Add($PopupState.Id); return $PopupState.Available }
    function Invoke-NotifyHotkeyBrokerActivateOldest { $script:BrokerFallbackCalls+=1; return $true }
    $script:EntryAttempts=[System.Collections.Generic.List[string]]::new()
    $script:BrokerFallbackCalls=0
    $script:EntryStates=@([pscustomobject]@{Id='fallback';Available=$true})
    Assert-Ui (Invoke-NotifyHotkeyOldestPopup) 'global hotkey reaches fallback'
    Assert-Ui (($script:EntryAttempts -join ',') -eq 'fallback' -and $script:BrokerFallbackCalls -eq 0) 'empty broker cannot swallow fallback hotkey'
    $script:EntryAttempts.Clear()
    $script:EntryStates=@(
        [pscustomobject]@{Id='stale';Available=$false}
        [pscustomobject]@{Id='next';Available=$true}
    )
    Assert-Ui (Invoke-NotifyHotkeyOldestPopup) 'global hotkey skips stale event'
    Assert-Ui (($script:EntryAttempts -join ',') -eq 'stale,next' -and $script:BrokerFallbackCalls -eq 0) 'global hotkey preserves oldest available order'
    $script:EntryStates=@()
    Assert-Ui (Invoke-NotifyHotkeyOldestPopup) 'broker fallback remains available if live state is missing'
    Assert-Ui ($script:BrokerFallbackCalls -eq 1) 'broker fallback only runs after live-state candidates'
}

# A persistent unavailable card must leave the hotkey queue, but a retryable card must stay.
& {
    . ([scriptblock]::Create((Get-TestFunctions $brokerAst @('Complete-NotifyBrokerPopupLifecycle'))))
    . ([scriptblock]::Create((Get-TestFunctions $popupAst @('Complete-NotifyPopupLifecycle'))))
    function Remove-NotifyBrokerLiveState { param($PopupId) $script:RemovedLiveStates+=1 }
    function Remove-NotifyPopupLiveState { $script:RemovedLiveStates+=1 }
    function Set-NotifyBrokerRecoveryUiState { param($Tag,$State) }
    function Set-NotifyPopupRecoveryUiState { param($State) }
    $script:NotifyBrokerFailureCloseDelayMs=2500
    $script:NotifyPopupFailureCloseDelayMs=2500
    foreach($surface in @('broker','fallback')) {
        foreach($retry in @($false,$true)) {
            $card=New-TestCard
            $card.OriginKind='paseo'
            $script:RemovedLiveStates=0
            try {
                $reason=if($retry){'daemon-down'}else{'invalid'}
                if($surface -eq 'broker') { $null=Complete-NotifyBrokerPopupLifecycle -Tag $card -Outcome failed -Reason $reason -Retryable $retry }
                else {
                    Set-TestFallbackState $card
                    $null=Complete-NotifyPopupLifecycle -Outcome failed -Reason $reason -Retryable $retry
                }
                Assert-Ui ($script:RemovedLiveStates -eq $(if($retry){0}else{1})) "$surface retry=$retry hotkey eligibility"
                Assert-Ui (-not $card.Form.IsDisposed) "$surface retry=$retry keeps feedback visible"
            } finally { Remove-TestCard $card }
        }
    }
}

# Close wins if a Paseo resolution and a hotkey arrive in the same timer tick.
$targetOriginKind='paseo'
$script:PaseoCloseRequested=$true
$script:StartedOrigins.Clear()
$script:NotifyPopupTerminalState=$false
$script:NotifyPopupDidActivate=$false
$key=[Guid]::NewGuid().ToString('N')
$script:NotifyPopupActivationEvent=[System.Threading.EventWaitHandle]::new($true,[System.Threading.EventResetMode]::AutoReset,(Get-NotifyPopupActivationEventName $PID $key))
$this=New-Object System.Windows.Forms.Timer
try {
    & $signalTick
    Assert-Ui ($script:NotifyPopupTerminalState -and $script:StartedOrigins.Count -eq 0) 'Paseo close wins over simultaneous hotkey'
} finally {
    $script:NotifyPopupActivationEvent.Dispose()
    $script:NotifyPopupActivationEvent=$null
    $this.Dispose()
    $script:PaseoCloseRequested=$false
}

foreach($height in @(154,185,186,351,352)) {
    $capacity=Get-NotifyPopupStackCapacity -WorkingAreaHeight $height -MaxVisible 4
    Assert-Ui ($capacity -eq $(if($height -eq 352){2}else{1})) "layout row boundary $height"
    $area=[System.Drawing.Rectangle]::new(-420,0,420,$height)
    $position=Get-NotifyPopupStackPosition -WorkingArea $area -StackIndex ($capacity-1) -FormWidth 420 -FormHeight 154
    Assert-Ui ($area.Contains([System.Drawing.Rectangle]::new($position.X,$position.Y,420,154))) "layout tight width/height $height"
}

# Exclusive log locks must never escape into the click/listener/hotkey callback.
$logPath=Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-log-'+[Guid]::NewGuid().ToString('N')+'.log')
[System.IO.File]::WriteAllText($logPath,'sentinel')
$lock=[System.IO.File]::Open($logPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
try {
    . ([scriptblock]::Create((Get-TestFunctions $popupAst @('Write-NotifyPopupLog'))))
    . ([scriptblock]::Create((Get-TestFunctions $hotkeyAst @('Write-NotifyHotkeyLog'))))
    . ([scriptblock]::Create((Get-TestFunctions $listenerAst @('Write-NotifyListenerLog'))))
    $script:NotifyPopupLogPath=$logPath
    $script:NotifyHotkeyLogPath=$logPath
    $script:NotifyListenerLogPath=$logPath
    Write-NotifyPopupLog -Message 'test'
    Write-NotifyHotkeyLog -Message 'test'
    Write-NotifyListenerLog -Message 'test'
    Assert-Ui $true 'locked log never interrupts popup, hotkey or listener'
} finally {
    $lock.Dispose()
    Assert-Ui ([System.IO.File]::ReadAllText($logPath) -eq 'sentinel') 'failed diagnostic append does not corrupt file'
    Remove-Item -LiteralPath $logPath -Force
}

Write-Output ("Popup UI checks passed: {0}" -f $script:PassCount)
