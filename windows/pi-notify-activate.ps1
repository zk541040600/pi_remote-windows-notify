[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Uri,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/terminal-route.ps1"
. "$PSScriptRoot/NotifyBridge.Activation.ps1"

Add-Type -AssemblyName System.Security

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs
$script:NotifyActivateLogPath = Join-Path (Get-NotifyBridgeLogDir) 'activate.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyActivateLogPath) | Out-Null

function Write-NotifyActivateLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyActivateLogPath -Value $line -Encoding UTF8
}

function Get-NotifyQueryValue {
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$ParsedUri,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $query = $ParsedUri.Query.TrimStart('?')
    if ([string]::IsNullOrWhiteSpace($query)) {
        return ''
    }

    foreach ($pair in $query -split '&') {
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $parts = $pair -split '=', 2
        $rawKey = if ($parts.Length -gt 0) { [string]$parts[0] } else { '' }
        $key = [Uri]::UnescapeDataString($rawKey.Replace('+', ' '))
        if ($key -ne $Name) {
            continue
        }

        if ($parts.Length -lt 2) {
            return ''
        }

        return [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
    }

    return ''
}

function Unprotect-NotifyActivationValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Resolve-NotifyActivationState {
    param([string]$ActivationId)
    if ([string]::IsNullOrWhiteSpace($ActivationId) -or $ActivationId -notmatch '^[0-9a-fA-F]{32}$') { return $null }
    $originKind = ''
    $paths = @(
        (Join-Path (Get-NotifyBridgeLogDir) ('activation-{0}.json' -f $ActivationId)),
        (Join-Path (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs') ('activation-{0}.json' -f $ActivationId))
    ) | Select-Object -Unique
    $path = @($paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if (@($path).Count -eq 0) { return $null }
    $path = [string]$path[0]
    try {
        $payload = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $originKind = if ($payload.PSObject.Properties['originKind'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.originKind)) { ([string]$payload.originKind).Trim() } else { '' }
        # Paseo toast cache is only an opaque handle pointer; do not consume here.
        # Terminal/pi-web retain one-shot consume semantics.
        if ($originKind -ne 'paseo') {
            foreach ($candidate in $paths) { Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue }
        }
        $expiresAtTicks = [int64]0
        if ($payload.PSObject.Properties['expiresAtTicks']) { [int64]::TryParse([string]$payload.expiresAtTicks, [ref]$expiresAtTicks) | Out-Null }
        if ($expiresAtTicks -le [DateTime]::UtcNow.Ticks) {
            foreach ($candidate in $paths) { Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue }
            if ($originKind -eq 'paseo') {
                return [pscustomobject]@{
                    FocusTarget = ''; CwdBase = ''; TabTitle = ''; OriginKind = 'paseo'; NotificationId = ''; SnapshotId = ''; RecoveryTicketId = ''
                    ActivationState = 'expired'
                }
            }
            return $null
        }
        $notificationId = if ($payload.PSObject.Properties['protectedNotificationId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.protectedNotificationId)) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedNotificationId) } else { '' }
        $snapshotId = if ($payload.PSObject.Properties['protectedSnapshotId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.protectedSnapshotId)) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedSnapshotId) } else { '' }
        $recoveryTicketId = if ($payload.PSObject.Properties['protectedRecoveryTicketId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.protectedRecoveryTicketId)) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedRecoveryTicketId) } else { '' }
        return [pscustomobject]@{
            FocusTarget    = if ($payload.PSObject.Properties['protectedHost']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedHost) } else { '' }
            CwdBase        = if ($payload.PSObject.Properties['protectedCwd']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedCwd) } else { '' }
            TabTitle       = if ($payload.PSObject.Properties['protectedTab']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedTab) } else { '' }
            OriginKind     = $originKind
            NotificationId = $notificationId
            SnapshotId     = $snapshotId
            RecoveryTicketId = $recoveryTicketId
            ActivationState = 'ready'
        }
    }
    catch {
        Write-NotifyActivateLog -Message ('activation-cache-read-error "{0}"' -f $_.Exception.Message)
        if ($originKind -eq 'paseo') {
            return [pscustomobject]@{
                FocusTarget = ''; CwdBase = ''; TabTitle = ''; OriginKind = 'paseo'; NotificationId = ''; SnapshotId = ''; RecoveryTicketId = ''
                ActivationState = 'invalid'
            }
        }
        return $null
    }
}

Write-NotifyActivateLog -Message ('activate-start hasUri={0}' -f (-not [string]::IsNullOrWhiteSpace($Uri)))

$targetHost = $config.RemoteHostAlias
$cwdBase = ''
$tabTitle = ''
$originKind = ''
$notificationId = ''
$snapshotId = ''
$recoveryTicketId = ''
$activationIdValue = ''
$activationStateResult = ''
if (-not [string]::IsNullOrWhiteSpace($Uri)) {
    try {
        $parsedUri = [Uri]$Uri
        $activationIdValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'id'
        $state = Resolve-NotifyActivationState -ActivationId $activationIdValue
        if ($null -ne $state) {
            if (-not [string]::IsNullOrWhiteSpace($state.FocusTarget)) { $targetHost = ([string]$state.FocusTarget).Trim() }
            if (-not [string]::IsNullOrWhiteSpace($state.CwdBase)) { $cwdBase = ([string]$state.CwdBase).Trim() }
            if (-not [string]::IsNullOrWhiteSpace($state.TabTitle)) { $tabTitle = ([string]$state.TabTitle).Trim() }
            if ($state.PSObject.Properties['OriginKind'] -and -not [string]::IsNullOrWhiteSpace([string]$state.OriginKind)) { $originKind = ([string]$state.OriginKind).Trim() }
            if ($state.PSObject.Properties['NotificationId'] -and -not [string]::IsNullOrWhiteSpace([string]$state.NotificationId)) { $notificationId = ([string]$state.NotificationId).Trim() }
            if ($state.PSObject.Properties['SnapshotId'] -and -not [string]::IsNullOrWhiteSpace([string]$state.SnapshotId)) { $snapshotId = ([string]$state.SnapshotId).Trim() }
            if ($state.PSObject.Properties['RecoveryTicketId'] -and -not [string]::IsNullOrWhiteSpace([string]$state.RecoveryTicketId)) { $recoveryTicketId = ([string]$state.RecoveryTicketId).Trim() }
            if ($state.PSObject.Properties['ActivationState']) { $activationStateResult = ([string]$state.ActivationState).Trim() }
        }
        else {
            $hostValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'host'
            $cwdBaseValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'cwdBase'
            $tabTitleValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'tabTitle'
            if (-not [string]::IsNullOrWhiteSpace($hostValue)) { $targetHost = $hostValue.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($cwdBaseValue)) { $cwdBase = $cwdBaseValue.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($tabTitleValue)) { $tabTitle = $tabTitleValue.Trim() }
        }
    }
    catch {
    }
}

# A resolved Paseo pointer is authoritative; inherited environment must not change its branch.
if ($originKind -ne 'paseo') {
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_FOCUS_TARGET)) { $targetHost = $env:PI_NOTIFY_FOCUS_TARGET.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_CWD_BASE)) { $cwdBase = $env:PI_NOTIFY_CWD_BASE.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TAB_TITLE)) { $tabTitle = $env:PI_NOTIFY_TAB_TITLE.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_ORIGIN_KIND)) { $originKind = $env:PI_NOTIFY_ORIGIN_KIND.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_NOTIFICATION_ID)) { $notificationId = $env:PI_NOTIFY_NOTIFICATION_ID.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_SNAPSHOT_ID)) { $snapshotId = $env:PI_NOTIFY_SNAPSHOT_ID.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_RECOVERY_TICKET_ID)) { $recoveryTicketId = $env:PI_NOTIFY_RECOVERY_TICKET_ID.Trim() }
}

if ($originKind -eq 'paseo' -and $activationStateResult -in @('expired', 'invalid')) {
    Write-NotifyActivateLog -Message ('activate-route fail-closed result={0} reason=toast-activation-state' -f $activationStateResult)
    exit 1
}

Write-NotifyActivateLog -Message ('activate-route originKind={0} notificationFp={1} snapshotFp={2}' -f $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'terminal' } else { $originKind }), (Get-NotifyRouteFingerprint -Value $notificationId), (Get-NotifyRouteFingerprint -Value $snapshotId))

$request = New-NotifyActivationRequest `
    -Version 1 `
    -Operation 'activate' `
    -OriginKind $originKind `
    -NotificationId $notificationId `
    -SnapshotId $snapshotId `
    -RecoveryTicketId $recoveryTicketId `
    -TargetHost $targetHost `
    -CwdBase $cwdBase `
    -TabTitle $tabTitle `
    -TargetFingerprint '' `
    -TimeoutMs $(if ($originKind -eq 'paseo') { 20000 } elseif ($originKind -eq 'pi-web') { 48000 } else { 3000 })

$outcome = Invoke-NotifyActivationStrategy -Request $request -Config $config -ActivationRecoveryWaitMs 125000
$ui = ConvertTo-NotifyActivationUiOutcome -Outcome $outcome
Write-NotifyActivateLog -Message ('activate-route decision={0} result={1} reason={2} proof={3} retryable={4} notificationFp={5} snapshotFp={6} scrollAttempted={7} scrolledToBottom={8}' -f $outcome.Decision, $outcome.Result, $(if ([string]::IsNullOrWhiteSpace([string]$outcome.Reason)) { 'none' } else { [string]$outcome.Reason }), $outcome.ProofState, $outcome.Retryable, (Get-NotifyRouteFingerprint -Value $notificationId), (Get-NotifyRouteFingerprint -Value ([string]$outcome.SnapshotId)), $outcome.ScrollAttempted, $outcome.ScrolledToBottom)

if ($ui.Action -eq 'close-handled' -or $ui.Action -eq 'close-focused') {
    if ($originKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($activationIdValue)) {
        try {
            $toastPaths = @(
                (Join-Path (Get-NotifyBridgeLogDir) ('activation-{0}.json' -f $activationIdValue)),
                (Join-Path (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs') ('activation-{0}.json' -f $activationIdValue))
            ) | Select-Object -Unique
            foreach ($candidate in $toastPaths) { Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    if ($ui.Action -eq 'close-focused') {
        Write-NotifyActivateLog -Message 'activate-route-focused background-proof=pending'
    }
    else {
        Write-NotifyActivateLog -Message 'activate-route-success'
    }
    exit 0
}

# Temporary Paseo failure: restore custom retry popup with same opaque activation id; never terminal fallback.
if ($originKind -eq 'paseo') {
    $retryable = [bool]$outcome.Retryable
    $permanent = ([string]$outcome.Result -in @('expired', 'invalid', 'activation-missing', 'foreign-owner', 'non-loopback', 'ambiguous'))
    if ($retryable -and -not $permanent -and [string]$outcome.Result -ne 'busy') {
        try {
            $retryState = Resolve-NotifyPaseoActivationState -ActivationId $snapshotId
            if (-not $retryState.Available) { exit 1 }
            $remainingSeconds = [int][Math]::Ceiling(([DateTime]::new([int64]$retryState.ExpiresAtTicks, [DateTimeKind]::Utc) - [DateTime]::UtcNow).TotalSeconds)
            if ($remainingSeconds -lt 3) { exit 1 }
            $retryFingerprint = Get-NotifyPaseoTargetFingerprint -ServerId $retryState.ServerId -AgentId $retryState.AgentId

            $popupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
            if (-not (Test-Path -LiteralPath $popupScript)) {
                $popupScript = Join-Path (Get-NotifyBridgeBinDir) 'pi-notify-popup.ps1'
            }
            if (Test-Path -LiteralPath $popupScript) {
                $retryTitle = -join @([char]0x8df3, [char]0x8f6c, [char]0x5931, [char]0x8d25, [char]0xff0c, [char]0x70b9, [char]0x51fb, [char]0x91cd, [char]0x8bd5)
                $retryBody = -join @([char]0x70b9, [char]0x51fb, [char]0x91cd, [char]0x8bd5)
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = Get-NotifyBridgePowerShellExe
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.Arguments = Join-NotifyBridgeProcessArguments @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $popupScript,
                    '-ConfigPath', ([string]$config.ConfigPath),
                    '-TargetFingerprint', $retryFingerprint,
                    '-TimeoutSeconds', $remainingSeconds
                )
                $psi.EnvironmentVariables['PI_NOTIFY_TITLE'] = $retryTitle
                $psi.EnvironmentVariables['PI_NOTIFY_BODY'] = $retryBody
                $psi.EnvironmentVariables['PI_NOTIFY_ORIGIN_KIND'] = 'paseo'
                $psi.EnvironmentVariables['PI_NOTIFY_NOTIFICATION_ID'] = $notificationId
                $psi.EnvironmentVariables['PI_NOTIFY_SNAPSHOT_ID'] = $snapshotId
                [void][System.Diagnostics.Process]::Start($psi)
                Write-NotifyActivateLog -Message ('activate-route-retry-popup result={0}' -f $outcome.Result)
            }
        }
        catch {
            Write-NotifyActivateLog -Message 'activate-route-retry-popup-error'
        }
    }
    Write-NotifyActivateLog -Message ('activate-route-fail-closed result={0}' -f $outcome.Result)
    exit 1
}

if ($originKind -eq 'pi-web') {
    # Exact Pi Web metadata is an authority boundary. Fail closed never falls through to Terminal.
    Write-NotifyActivateLog -Message ('activate-route-fail-closed result={0} reason={1}' -f $outcome.Result, $(if ([string]::IsNullOrWhiteSpace([string]$outcome.Reason)) { 'none' } else { [string]$outcome.Reason }))
    exit 1
}

Write-NotifyActivateLog -Message ('activate-focus-miss result={0} reason={1}' -f $outcome.Result, $(if ([string]::IsNullOrWhiteSpace([string]$outcome.Reason)) { 'none' } else { [string]$outcome.Reason }))
exit 1
