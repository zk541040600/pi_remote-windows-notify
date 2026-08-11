# Shared notification activation coordinator.
# Load after NotifyBridge.Common.ps1 and terminal-route.ps1.
# Owns origin selection, strategy invocation, normalized outcomes, and pure UI mapping.

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'Invoke-NotifyPaseoRouteActivate' -ErrorAction SilentlyContinue)) {
    throw 'NotifyBridge.Activation.ps1 must be dot-sourced after NotifyBridge.Common.ps1'
}
if (-not (Get-Command -Name 'Invoke-NotifyTerminalRouteActivate' -ErrorAction SilentlyContinue)) {
    throw 'NotifyBridge.Activation.ps1 must be dot-sourced after terminal-route.ps1'
}
if (-not (Get-Command -Name 'Invoke-NotifyExactRouteRecoveryAndActivate' -ErrorAction SilentlyContinue)) {
    throw 'NotifyBridge.Activation.ps1 requires Invoke-NotifyExactRouteRecoveryAndActivate from NotifyBridge.Common.ps1'
}
if (-not (Get-Command -Name 'Wait-NotifyExactRouteRecovery' -ErrorAction SilentlyContinue)) {
    throw 'NotifyBridge.Activation.ps1 requires Wait-NotifyExactRouteRecovery from NotifyBridge.Common.ps1'
}

# Normalize declared originKind. Blank becomes legacy terminal; unknown fails closed.
function Normalize-NotifyActivationOriginKind {
    param([string]$OriginKind = '')

    if ($null -eq $OriginKind -or [string]::IsNullOrWhiteSpace($OriginKind)) {
        return [pscustomobject]@{ Ok = $true; OriginKind = 'terminal'; Reason = 'legacy-blank-origin' }
    }

    $kind = $OriginKind.Trim()
    if ($kind -eq 'terminal' -or $kind -eq 'paseo' -or $kind -eq 'pi-web') {
        return [pscustomobject]@{ Ok = $true; OriginKind = $kind; Reason = '' }
    }

    return [pscustomobject]@{ Ok = $false; OriginKind = ''; Reason = 'unsupported-origin' }
}

# Build a versioned activation request object with scalar fields only.
function New-NotifyActivationRequest {
    param(
        [int]$Version = 1,
        [string]$Operation = 'activate',
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [string]$TargetHost = '',
        [string]$CwdBase = '',
        [string]$TabTitle = '',
        [string]$TargetFingerprint = '',
        [int]$TimeoutMs = 0
    )

    return [pscustomobject]@{
        Version           = [int]$Version
        Operation         = if ($null -eq $Operation) { '' } else { [string]$Operation }
        OriginKind        = if ($null -eq $OriginKind) { '' } else { [string]$OriginKind }
        NotificationId    = if ($null -eq $NotificationId) { '' } else { [string]$NotificationId }
        SnapshotId        = if ($null -eq $SnapshotId) { '' } else { [string]$SnapshotId }
        RecoveryTicketId  = if ($null -eq $RecoveryTicketId) { '' } else { [string]$RecoveryTicketId }
        TargetHost        = if ($null -eq $TargetHost) { '' } else { [string]$TargetHost }
        CwdBase           = if ($null -eq $CwdBase) { '' } else { [string]$CwdBase }
        TabTitle          = if ($null -eq $TabTitle) { '' } else { [string]$TabTitle }
        TargetFingerprint = if ($null -eq $TargetFingerprint) { '' } else { [string]$TargetFingerprint }
        TimeoutMs         = [int]$TimeoutMs
    }
}

# Build a complete normalized activation outcome.
function New-NotifyActivationOutcome {
    param(
        [string]$Operation = 'activate',
        [string]$OriginKind = '',
        [Parameter(Mandatory = $true)][string]$Decision,
        [string]$Result = '',
        [string]$Reason = '',
        [bool]$Retryable = $false,
        [string]$ProofState = 'none',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [bool]$ScrollAttempted = $false,
        [bool]$ScrolledToBottom = $false,
        [int]$ElapsedMs = 0
    )

    $decision = if ([string]::IsNullOrWhiteSpace($Decision)) { 'fail-closed' } else { $Decision.Trim() }
    $proof = if ([string]::IsNullOrWhiteSpace($ProofState)) { 'none' } else { $ProofState.Trim() }
    if ($decision -eq 'handled') {
        $proof = 'final'
        $Retryable = $false
    }
    elseif ($decision -eq 'focused') {
        $proof = 'pending'
    }
    elseif ($decision -eq 'ready') {
        $proof = 'none'
        $Retryable = $false
    }
    elseif ($decision -ne 'fail-closed') {
        $decision = 'fail-closed'
        $proof = 'none'
        if ([string]::IsNullOrWhiteSpace($Result)) { $Result = 'strategy-contract-invalid' }
        if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'invalid-decision' }
    }

    return [pscustomobject]@{
        Version          = 1
        Operation        = if ([string]::IsNullOrWhiteSpace($Operation)) { 'activate' } else { $Operation.Trim() }
        OriginKind       = if ($null -eq $OriginKind) { '' } else { [string]$OriginKind }
        Decision         = $decision
        Result           = if ($null -eq $Result) { '' } else { [string]$Result }
        Reason           = if ($null -eq $Reason) { '' } else { [string]$Reason }
        Retryable        = [bool]$Retryable
        ProofState       = $proof
        SnapshotId       = if ($null -eq $SnapshotId) { '' } else { [string]$SnapshotId }
        RecoveryTicketId = if ($null -eq $RecoveryTicketId) { '' } else { [string]$RecoveryTicketId }
        ScrollAttempted  = [bool]$ScrollAttempted
        ScrolledToBottom = [bool]($ScrollAttempted -and $ScrolledToBottom)
        ElapsedMs        = [Math]::Max(0, [int]$ElapsedMs)
    }
}

# Reject malformed strategy returns instead of treating them as success.
function Test-NotifyActivationStrategyResult {
    param(
        $Result,
        [string]$ExpectedOperation = '',
        [string]$ExpectedOriginKind = ''
    )

    if ($null -eq $Result) { return $false }
    try {
        $requiredNames = @(
            'Version', 'Operation', 'OriginKind', 'Decision', 'Result', 'Reason',
            'Retryable', 'ProofState', 'SnapshotId', 'RecoveryTicketId',
            'ScrollAttempted', 'ScrolledToBottom', 'ElapsedMs'
        )
        foreach ($name in $requiredNames) {
            if (-not $Result.PSObject.Properties[$name]) { return $false }
        }

        if ([int]$Result.Version -ne 1) { return $false }
        $operation = [string]$Result.Operation
        $origin = [string]$Result.OriginKind
        $decision = [string]$Result.Decision
        $proof = [string]$Result.ProofState
        if ($Result.Retryable -isnot [bool]) { return $false }
        if ($Result.ScrollAttempted -isnot [bool] -or $Result.ScrolledToBottom -isnot [bool]) { return $false }
        $retryable = [bool]$Result.Retryable
        $scrollAttempted = [bool]$Result.ScrollAttempted
        $scrolledToBottom = [bool]$Result.ScrolledToBottom
        if ($scrolledToBottom -and -not $scrollAttempted) { return $false }
        if ($origin -ne 'terminal' -and ($scrollAttempted -or $scrolledToBottom)) { return $false }
        if ($operation -notin @('resolve', 'activate')) { return $false }
        $isUnsupportedOrigin = (
            [string]::IsNullOrWhiteSpace($origin) -and
            $decision -eq 'fail-closed' -and
            [string]$Result.Result -eq 'unsupported-origin' -and
            [string]$Result.Reason -eq 'unsupported-origin')
        if (-not $isUnsupportedOrigin -and $origin -notin @('terminal', 'paseo', 'pi-web')) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOperation) -and $operation -ne $ExpectedOperation) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginKind) -and $origin -ne $ExpectedOriginKind) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$Result.Result)) { return $false }
        if ([int64]$Result.ElapsedMs -lt 0) { return $false }

        if ($decision -eq 'ready') {
            return ($operation -eq 'resolve' -and $origin -eq 'pi-web' -and $proof -eq 'none' -and -not $retryable -and -not [string]::IsNullOrWhiteSpace([string]$Result.SnapshotId))
        }
        if ($decision -eq 'handled') {
            return ($operation -eq 'activate' -and $proof -eq 'final' -and -not $retryable)
        }
        if ($decision -eq 'focused') {
            return ($operation -eq 'activate' -and $origin -eq 'pi-web' -and $proof -eq 'pending' -and -not $retryable -and -not [string]::IsNullOrWhiteSpace([string]$Result.SnapshotId))
        }
        if ($decision -eq 'fail-closed') {
            return ($proof -eq 'none')
        }
        return $false
    }
    catch {
        return $false
    }
}

# Build a complete fail-closed result for worker infrastructure failures.
function New-NotifyActivationWorkerFailureOutcome {
    param(
        [string]$Operation = 'activate',
        [string]$OriginKind = '',
        [string]$Reason = 'worker-error',
        [int]$ElapsedMs = 0,
        [bool]$Retryable = $false
    )

    $normalizedOperation = if ($Operation -eq 'resolve') { 'resolve' } else { 'activate' }
    $originInfo = Normalize-NotifyActivationOriginKind -OriginKind $OriginKind
    $normalizedOrigin = if ($originInfo.Ok) { [string]$originInfo.OriginKind } elseif ($normalizedOperation -eq 'resolve') { 'pi-web' } else { 'terminal' }
    return (New-NotifyActivationOutcome -Operation $normalizedOperation -OriginKind $normalizedOrigin -Decision 'fail-closed' -Result 'worker-error' -Reason $Reason -Retryable:$Retryable -ProofState 'none' -ElapsedMs $ElapsedMs)
}

# Require exactly one complete worker result; empty, multiple, or malformed output fails closed.
function Resolve-NotifyActivationWorkerOutput {
    param(
        $Rows = @(),
        [string]$Operation = 'activate',
        [string]$OriginKind = '',
        [int]$ElapsedMs = 0
    )

    $items = @($Rows)
    if ($items.Count -eq 0) {
        return (New-NotifyActivationWorkerFailureOutcome -Operation $Operation -OriginKind $OriginKind -Reason 'worker-empty' -ElapsedMs $ElapsedMs)
    }
    if ($items.Count -ne 1) {
        return (New-NotifyActivationWorkerFailureOutcome -Operation $Operation -OriginKind $OriginKind -Reason 'worker-output-count' -ElapsedMs $ElapsedMs)
    }

    $originInfo = Normalize-NotifyActivationOriginKind -OriginKind $OriginKind
    $expectedOrigin = if ($originInfo.Ok) {
        [string]$originInfo.OriginKind
    }
    elseif (-not [string]::IsNullOrWhiteSpace($OriginKind)) {
        ''
    }
    elseif ($Operation -eq 'resolve') {
        'pi-web'
    }
    else {
        'terminal'
    }
    if (-not (Test-NotifyActivationStrategyResult -Result $items[0] -ExpectedOperation $Operation -ExpectedOriginKind $expectedOrigin)) {
        return (New-NotifyActivationWorkerFailureOutcome -Operation $Operation -OriginKind $expectedOrigin -Reason 'worker-malformed' -ElapsedMs $ElapsedMs)
    }
    return $items[0]
}

# Compute the remaining immutable popup lifetime with an injectable clock.
function Get-NotifyActivationRemainingMs {
    param(
        [Parameter(Mandatory = $true)][DateTime]$ExpiresAtUtc,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $remaining = ($ExpiresAtUtc.ToUniversalTime() - $NowUtc.ToUniversalTime()).TotalMilliseconds
    if ($remaining -le 0) { return 0 }
    return [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($remaining))
}

# Pure UI lifecycle mapping. Does not touch WinForms controls.
function ConvertTo-NotifyActivationUiOutcome {
    param(
        [Parameter(Mandatory = $true)]$Outcome,
        [bool]$HasDeferredActivateIntent = $false
    )

    if (-not (Test-NotifyActivationStrategyResult -Result $Outcome)) {
        return [pscustomobject]@{
            Action               = 'show-unavailable'
            Decision             = 'fail-closed'
            Result               = 'strategy-contract-invalid'
            Reason               = 'invalid-strategy-result'
            Retryable            = $false
            SnapshotId           = ''
            RecoveryTicketId     = ''
            StartActivate        = $false
            ClaimFinalActivation = $false
        }
    }

    $decision = [string]$Outcome.Decision
    $result = [string]$Outcome.Result
    $reason = [string]$Outcome.Reason
    $retryable = [bool]$Outcome.Retryable
    $snapshotId = if ($Outcome.PSObject.Properties['SnapshotId']) { [string]$Outcome.SnapshotId } else { '' }
    $ticketId = if ($Outcome.PSObject.Properties['RecoveryTicketId']) { [string]$Outcome.RecoveryTicketId } else { '' }

    if ($decision -eq 'ready') {
        return [pscustomobject]@{
            Action               = 'store-ready'
            Decision             = $decision
            Result               = $result
            Reason               = $reason
            Retryable            = $false
            SnapshotId           = $snapshotId
            RecoveryTicketId     = $ticketId
            StartActivate        = [bool]$HasDeferredActivateIntent
            ClaimFinalActivation = $false
        }
    }

    if ($decision -eq 'handled') {
        return [pscustomobject]@{
            Action               = 'close-handled'
            Decision             = $decision
            Result               = $(if ([string]::IsNullOrWhiteSpace($result)) { 'activation-handled' } else { $result })
            Reason               = $reason
            Retryable            = $false
            SnapshotId           = $snapshotId
            RecoveryTicketId     = $ticketId
            StartActivate        = $false
            ClaimFinalActivation = $true
        }
    }

    if ($decision -eq 'focused') {
        return [pscustomobject]@{
            Action               = 'close-focused'
            Decision             = $decision
            Result               = $(if ([string]::IsNullOrWhiteSpace($result)) { 'pending' } else { $result })
            Reason               = $(if ([string]::IsNullOrWhiteSpace($reason)) { 'background-proof-pending' } else { $reason })
            Retryable            = $false
            SnapshotId           = $snapshotId
            RecoveryTicketId     = $ticketId
            StartActivate        = $false
            ClaimFinalActivation = $false
        }
    }

    if ($retryable) {
        return [pscustomobject]@{
            Action               = 'restore-retryable'
            Decision             = $decision
            Result               = $(if ([string]::IsNullOrWhiteSpace($result)) { 'activation-failed' } else { $result })
            Reason               = $(if ([string]::IsNullOrWhiteSpace($reason)) { $result } else { $reason })
            Retryable            = $true
            SnapshotId           = $snapshotId
            RecoveryTicketId     = $ticketId
            StartActivate        = $false
            ClaimFinalActivation = $false
        }
    }

    return [pscustomobject]@{
        Action               = 'show-unavailable'
        Decision             = $decision
        Result               = $(if ([string]::IsNullOrWhiteSpace($result)) { 'activation-failed' } else { $result })
        Reason               = $(if ([string]::IsNullOrWhiteSpace($reason)) { $result } else { $reason })
        Retryable            = $false
        SnapshotId           = $snapshotId
        RecoveryTicketId     = $ticketId
        StartActivate        = $false
        ClaimFinalActivation = $false
    }
}

# Terminal strategy over the shared WT route adapter.
function Invoke-NotifyTerminalActivationStrategy {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [int]$TimeoutMs = 3000
    )

    $startedAt = [DateTime]::UtcNow
    $tabTitle = if ($Request.PSObject.Properties['TabTitle']) { [string]$Request.TabTitle } else { '' }
    $cwdBase = if ($Request.PSObject.Properties['CwdBase']) { [string]$Request.CwdBase } else { '' }
    $targetHost = if ($Request.PSObject.Properties['TargetHost']) { [string]$Request.TargetHost } else { '' }
    $targetFingerprint = if ($Request.PSObject.Properties['TargetFingerprint']) { [string]$Request.TargetFingerprint } else { '' }
    $budget = if ($TimeoutMs -gt 0) { $TimeoutMs } else { 3000 }

    $terminal = Invoke-NotifyTerminalRouteActivate -TabTitle $tabTitle -CwdBase $cwdBase -TargetHost $targetHost -TargetFingerprint $targetFingerprint -TimeoutMs $budget
    $elapsed = if ($terminal.PSObject.Properties['ElapsedMs']) { [int]$terminal.ElapsedMs } else { [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds }
    $decision = if ($terminal.PSObject.Properties['Decision']) { [string]$terminal.Decision } else { 'fail-closed' }
    $result = if ($terminal.PSObject.Properties['Result']) { [string]$terminal.Result } else { 'controller-error' }
    $reason = if ($terminal.PSObject.Properties['Reason']) { [string]$terminal.Reason } else { '' }
    $retryable = if ($terminal.PSObject.Properties['Retryable']) { [bool]$terminal.Retryable } else { $false }
    $proof = if ($terminal.PSObject.Properties['ProofState']) { [string]$terminal.ProofState } else { 'none' }
    $scrollAttempted = if ($terminal.PSObject.Properties['ScrollAttempted']) { [bool]$terminal.ScrollAttempted } else { $false }
    $scrolledToBottom = if ($terminal.PSObject.Properties['ScrolledToBottom']) { [bool]$terminal.ScrolledToBottom } else { $false }

    return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'terminal' -Decision $decision -Result $result -Reason $reason -Retryable:$retryable -ProofState $proof -ScrollAttempted:$scrollAttempted -ScrolledToBottom:$scrolledToBottom -ElapsedMs $elapsed)
}

# Paseo strategy: thin adapter over existing DPAPI/CDP authority.
function Invoke-NotifyPaseoActivationStrategy {
    param(
        [Parameter(Mandatory = $true)]$Request,
        $Config = $null,
        [int]$TimeoutMs = 20000
    )

    $startedAt = [DateTime]::UtcNow
    $activationId = if ($Request.PSObject.Properties['SnapshotId']) { [string]$Request.SnapshotId } else { '' }
    if ([string]::IsNullOrWhiteSpace($activationId)) {
        return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'paseo' -Decision 'fail-closed' -Result 'activation-missing' -Reason 'missing-activation-handle' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    $budget = if ($TimeoutMs -gt 0) { $TimeoutMs } else { 20000 }
    $outcome = Invoke-NotifyPaseoRouteActivate -ActivationId $activationId -Config $Config -TimeoutMs $budget
    $decision = if ($outcome.PSObject.Properties['Decision']) { [string]$outcome.Decision } else { 'fail-closed' }
    $result = if ($outcome.PSObject.Properties['Result']) { [string]$outcome.Result } else { 'activation-failed' }
    $reason = if ($outcome.PSObject.Properties['Reason']) { [string]$outcome.Reason } else { '' }
    $retryable = if ($outcome.PSObject.Properties['Retryable']) { [bool]$outcome.Retryable } else { $false }
    $elapsed = if ($outcome.PSObject.Properties['ElapsedMs']) { [int]$outcome.ElapsedMs } else { [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds }

    if ($decision -eq 'handled' -and $result -eq 'activated') {
        return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'paseo' -Decision 'handled' -Result 'activated' -Reason '' -Retryable:$false -ProofState 'final' -SnapshotId $activationId -ElapsedMs $elapsed)
    }

    return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'paseo' -Decision 'fail-closed' -Result $result -Reason $reason -Retryable:$retryable -ProofState 'none' -SnapshotId $activationId -ElapsedMs $elapsed)
}

# Pi Web strategy over recovery/activate helpers and existing decision validation.
function Invoke-NotifyPiWebActivationStrategy {
    param(
        [Parameter(Mandatory = $true)]$Request,
        $Config = $null,
        [int]$ActivationRecoveryWaitMs = 10000
    )

    $startedAt = [DateTime]::UtcNow
    $operation = if ($Request.PSObject.Properties['Operation']) { ([string]$Request.Operation).Trim() } else { 'activate' }
    $notificationId = if ($Request.PSObject.Properties['NotificationId']) { [string]$Request.NotificationId } else { '' }
    $snapshotId = if ($Request.PSObject.Properties['SnapshotId']) { [string]$Request.SnapshotId } else { '' }
    $ticketId = if ($Request.PSObject.Properties['RecoveryTicketId']) { [string]$Request.RecoveryTicketId } else { '' }

    if ($operation -eq 'resolve') {
        $outcome = Wait-NotifyExactRouteRecovery -NotificationId $notificationId -RecoveryTicketId $ticketId -Config $Config -WaitMs 125000
        $decision = $outcome.Decision
        $resolvedSnapshot = if ($outcome.PSObject.Properties['SnapshotId']) { [string]$outcome.SnapshotId } elseif ($decision.PSObject.Properties['SnapshotId']) { [string]$decision.SnapshotId } else { '' }
        $decisionName = if ($decision.PSObject.Properties['Decision']) { [string]$decision.Decision } else { '' }
        $resultName = if ($decision.PSObject.Properties['Result']) { [string]$decision.Result } else { '' }
        $reasonName = if ($decision.PSObject.Properties['Reason']) { [string]$decision.Reason } else { '' }

        if (($decisionName -eq 'exact-ready' -or $decisionName -eq 'ready') -and -not [string]::IsNullOrWhiteSpace($resolvedSnapshot)) {
            return (New-NotifyActivationOutcome -Operation 'resolve' -OriginKind 'pi-web' -Decision 'ready' -Result $(if ([string]::IsNullOrWhiteSpace($resultName)) { 'ready' } else { $resultName }) -Reason $reasonName -Retryable:$false -SnapshotId $resolvedSnapshot -RecoveryTicketId $ticketId -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        return (New-NotifyActivationOutcome -Operation 'resolve' -OriginKind 'pi-web' -Decision 'fail-closed' -Result $(if ([string]::IsNullOrWhiteSpace($resultName)) { 'resolve-failed' } else { $resultName }) -Reason $(if ([string]::IsNullOrWhiteSpace($reasonName)) { 'resolve-failed' } else { $reasonName }) -Retryable:$false -RecoveryTicketId $ticketId -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    $outcome = Invoke-NotifyExactRouteRecoveryAndActivate -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $ticketId -Config $Config -RecoveryWaitMs $ActivationRecoveryWaitMs -ActivateWaitMs 45000 -ActivateTimeoutMs 48000
    $decision = $outcome.Decision
    $resolvedSnapshot = if ($outcome.PSObject.Properties['SnapshotId']) { [string]$outcome.SnapshotId } elseif ($decision.PSObject.Properties['SnapshotId']) { [string]$decision.SnapshotId } else { $snapshotId }
    $decisionName = if ($decision.PSObject.Properties['Decision']) { [string]$decision.Decision } else { '' }
    $resultName = if ($decision.PSObject.Properties['Result']) { [string]$decision.Result } else { '' }
    $reasonName = if ($decision.PSObject.Properties['Reason']) { [string]$decision.Reason } else { '' }

    if ($decisionName -eq 'handled') {
        return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'pi-web' -Decision 'handled' -Result $(if ([string]::IsNullOrWhiteSpace($resultName)) { 'activation-handled' } else { $resultName }) -Reason $reasonName -Retryable:$false -ProofState 'final' -SnapshotId $resolvedSnapshot -RecoveryTicketId $ticketId -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
    if ($decisionName -eq 'focused') {
        return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'pi-web' -Decision 'focused' -Result $(if ([string]::IsNullOrWhiteSpace($resultName)) { 'pending' } else { $resultName }) -Reason $(if ([string]::IsNullOrWhiteSpace($reasonName)) { 'background-proof-pending' } else { $reasonName }) -Retryable:$false -ProofState 'pending' -SnapshotId $resolvedSnapshot -RecoveryTicketId $ticketId -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    return (New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'pi-web' -Decision 'fail-closed' -Result $(if ([string]::IsNullOrWhiteSpace($resultName)) { 'activation-failed' } else { $resultName }) -Reason $(if ([string]::IsNullOrWhiteSpace($reasonName)) { 'activation-failed' } else { $reasonName }) -Retryable:$false -SnapshotId $resolvedSnapshot -RecoveryTicketId $ticketId -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
}

# Coordinator entry: validate request, select strategy, normalize outcome.
function Invoke-NotifyActivationStrategy {
    param(
        $Request,
        $Config = $null,
        [int]$ActivationRecoveryWaitMs = 10000
    )

    $startedAt = [DateTime]::UtcNow
    if ($null -eq $Request) {
        return (New-NotifyActivationOutcome -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'missing-request' -Retryable:$false -ElapsedMs 0)
    }

    $version = 0
    if ($Request.PSObject.Properties['Version']) {
        [void][int]::TryParse([string]$Request.Version, [ref]$version)
    }
    if ($version -ne 1) {
        return (New-NotifyActivationOutcome -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'unsupported-version' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    $operation = if ($Request.PSObject.Properties['Operation']) { ([string]$Request.Operation).Trim() } else { 'activate' }
    if ($operation -notin @('resolve', 'activate')) {
        return (New-NotifyActivationOutcome -Operation $operation -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'unsupported-operation' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    $originRaw = if ($Request.PSObject.Properties['OriginKind']) { [string]$Request.OriginKind } else { '' }
    $originInfo = Normalize-NotifyActivationOriginKind -OriginKind $originRaw
    if (-not $originInfo.Ok) {
        return (New-NotifyActivationOutcome -Operation $operation -OriginKind '' -Decision 'fail-closed' -Result 'unsupported-origin' -Reason 'unsupported-origin' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
    $origin = [string]$originInfo.OriginKind

    if ($operation -eq 'resolve' -and $origin -ne 'pi-web') {
        return (New-NotifyActivationOutcome -Operation $operation -OriginKind $origin -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'resolve-requires-pi-web' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    $notificationId = if ($Request.PSObject.Properties['NotificationId']) { [string]$Request.NotificationId } else { '' }
    $snapshotId = if ($Request.PSObject.Properties['SnapshotId']) { [string]$Request.SnapshotId } else { '' }
    $ticketId = if ($Request.PSObject.Properties['RecoveryTicketId']) { [string]$Request.RecoveryTicketId } else { '' }
    $timeoutMs = 0
    if ($Request.PSObject.Properties['TimeoutMs']) {
        [void][int]::TryParse([string]$Request.TimeoutMs, [ref]$timeoutMs)
    }

    try {
        if ($origin -eq 'paseo') {
            if ([string]::IsNullOrWhiteSpace($snapshotId)) {
                return (New-NotifyActivationOutcome -Operation $operation -OriginKind 'paseo' -Decision 'fail-closed' -Result 'activation-missing' -Reason 'missing-activation-handle' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            $strategy = Invoke-NotifyPaseoActivationStrategy -Request $Request -Config $Config -TimeoutMs $(if ($timeoutMs -gt 0) { $timeoutMs } else { 20000 })
        }
        elseif ($origin -eq 'pi-web') {
            if ([string]::IsNullOrWhiteSpace($notificationId)) {
                return (New-NotifyActivationOutcome -Operation $operation -OriginKind 'pi-web' -Decision 'fail-closed' -Result 'owner-unresolved' -Reason 'missing-notification-id' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            if ($operation -eq 'activate' -and [string]::IsNullOrWhiteSpace($snapshotId) -and [string]::IsNullOrWhiteSpace($ticketId)) {
                return (New-NotifyActivationOutcome -Operation $operation -OriginKind 'pi-web' -Decision 'fail-closed' -Result 'owner-unresolved' -Reason 'missing-route-handle' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            if ($operation -eq 'resolve' -and [string]::IsNullOrWhiteSpace($ticketId)) {
                return (New-NotifyActivationOutcome -Operation $operation -OriginKind 'pi-web' -Decision 'fail-closed' -Result 'owner-unresolved' -Reason 'missing-recovery-ticket' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            $strategy = Invoke-NotifyPiWebActivationStrategy -Request $Request -Config $Config -ActivationRecoveryWaitMs $ActivationRecoveryWaitMs
        }
        else {
            $tabTitle = if ($Request.PSObject.Properties['TabTitle']) { [string]$Request.TabTitle } else { '' }
            $cwdBase = if ($Request.PSObject.Properties['CwdBase']) { [string]$Request.CwdBase } else { '' }
            if ([string]::IsNullOrWhiteSpace($tabTitle) -and [string]::IsNullOrWhiteSpace($cwdBase)) {
                return (New-NotifyActivationOutcome -Operation $operation -OriginKind 'terminal' -Decision 'fail-closed' -Result 'missing-target-metadata' -Reason 'missing-target-metadata' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            $strategy = Invoke-NotifyTerminalActivationStrategy -Request $Request -TimeoutMs $(if ($timeoutMs -gt 0) { $timeoutMs } else { 3000 })
        }
    }
    catch {
        return (New-NotifyActivationOutcome -Operation $operation -OriginKind $origin -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'strategy-exception' -Retryable:$false -ProofState 'none' -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }

    if (-not (Test-NotifyActivationStrategyResult -Result $strategy -ExpectedOperation $operation -ExpectedOriginKind $origin)) {
        return (New-NotifyActivationOutcome -Operation $operation -OriginKind $origin -Decision 'fail-closed' -Result 'strategy-contract-invalid' -Reason 'invalid-strategy-result' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
    return $strategy
}

# Reusable worker body for runspaces. Receives scalar fields and module paths only.
function Invoke-NotifyActivationWorkerBody {
    param(
        [Parameter(Mandatory = $true)][string]$CommonPath,
        [Parameter(Mandatory = $true)][string]$TerminalRoutePath,
        [Parameter(Mandatory = $true)][string]$ActivationPath,
        [string]$ConfigPath = '',
        [string]$Operation = 'activate',
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [string]$TargetHost = '',
        [string]$CwdBase = '',
        [string]$TabTitle = '',
        [string]$TargetFingerprint = '',
        [int]$TimeoutMs = 0,
        [int]$ActivationRecoveryWaitMs = 10000
    )

    $startedAt = [DateTime]::UtcNow
    try {
        $ErrorActionPreference = 'Stop'
        foreach ($modulePath in @($CommonPath, $TerminalRoutePath, $ActivationPath)) {
            if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
                throw 'worker-module-missing'
            }
        }
        . $CommonPath
        . $TerminalRoutePath
        . $ActivationPath

        $configArgs = @{}
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $configArgs.ConfigPath = $ConfigPath }
        $workerConfig = Ensure-NotifyBridgeConfig @configArgs
        $request = New-NotifyActivationRequest -Version 1 -Operation $Operation -OriginKind $OriginKind -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId -TargetHost $TargetHost -CwdBase $CwdBase -TabTitle $TabTitle -TargetFingerprint $TargetFingerprint -TimeoutMs $TimeoutMs
        return (Invoke-NotifyActivationStrategy -Request $request -Config $workerConfig -ActivationRecoveryWaitMs $ActivationRecoveryWaitMs)
    }
    catch {
        return (New-NotifyActivationWorkerFailureOutcome -Operation $Operation -OriginKind $OriginKind -Reason 'worker-exception' -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
}

# Script text for PowerShell.BeginInvoke workers. Uses only scalar parameters.
function Get-NotifyActivationWorkerScript {
    return @'
param(
    $CommonPath,
    $TerminalRoutePath,
    $ActivationPath,
    $ConfigPath,
    $Operation,
    $OriginKind,
    $NotificationId,
    $SnapshotId,
    $RecoveryTicketId,
    $TargetHost,
    $CwdBase,
    $TabTitle,
    $TargetFingerprint,
    $TimeoutMs,
    $ActivationRecoveryWaitMs
)
$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
try {
    foreach ($modulePath in @($CommonPath, $TerminalRoutePath, $ActivationPath)) {
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw 'worker-module-missing'
        }
    }
    . $CommonPath
    . $TerminalRoutePath
    . $ActivationPath
    $configArgs = @{}
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $configArgs.ConfigPath = $ConfigPath }
    $workerConfig = Ensure-NotifyBridgeConfig @configArgs
    $request = New-NotifyActivationRequest -Version 1 -Operation $Operation -OriginKind $OriginKind -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId -TargetHost $TargetHost -CwdBase $CwdBase -TabTitle $TabTitle -TargetFingerprint $TargetFingerprint -TimeoutMs ([int]$TimeoutMs)
    Invoke-NotifyActivationStrategy -Request $request -Config $workerConfig -ActivationRecoveryWaitMs ([int]$ActivationRecoveryWaitMs)
}
catch {
    $normalizedOperation = if ([string]$Operation -eq 'resolve') { 'resolve' } else { 'activate' }
    $normalizedOrigin = if ([string]::IsNullOrWhiteSpace([string]$OriginKind)) {
        if ($normalizedOperation -eq 'resolve') { 'pi-web' } else { 'terminal' }
    }
    elseif ([string]$OriginKind -in @('terminal', 'paseo', 'pi-web')) {
        [string]$OriginKind
    }
    elseif ($normalizedOperation -eq 'resolve') {
        'pi-web'
    }
    else {
        'terminal'
    }
    [pscustomobject]@{
        Version = 1
        Operation = $normalizedOperation
        OriginKind = $normalizedOrigin
        Decision = 'fail-closed'
        Result = 'worker-error'
        Reason = 'worker-exception'
        Retryable = $false
        ProofState = 'none'
        SnapshotId = ''
        RecoveryTicketId = ''
        ScrollAttempted = $false
        ScrolledToBottom = $false
        ElapsedMs = [Math]::Max(0, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
    }
}
'@
}
