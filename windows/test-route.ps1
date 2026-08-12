# Pure route-decision tests for Windows notify exact-route integration.
# Runnable with pwsh or Windows PowerShell; no live focus-changing action is performed.
[CmdletBinding()]
param(
    [switch]$SkipDotSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CanTestActivationModules = ($env:OS -eq 'Windows_NT')
if (-not $SkipDotSource) {
    . (Join-Path $scriptDir 'NotifyBridge.Common.ps1')
    if ($script:CanTestActivationModules) {
        . (Join-Path $scriptDir 'terminal-route.ps1')
        . (Join-Path $scriptDir 'NotifyBridge.Activation.ps1')
    }
}

$script:TestFailures = 0
$script:TestPasses = 0

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:TestPasses += 1
        Write-Host ("PASS  {0}" -f $Name)
    }
    else {
        $script:TestFailures += 1
        $msg = if ($Detail) { "$Name :: $Detail" } else { $Name }
        Write-Host ("FAIL  {0}" -f $msg)
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -eq "$Actual") {
        $script:TestPasses += 1
        Write-Host ("PASS  {0}" -f $Name)
    }
    else {
        $script:TestFailures += 1
        Write-Host ("FAIL  {0} expected={1} actual={2}" -f $Name, $Expected, $Actual)
    }
}

function New-ValidPiWebPayload {
    return [pscustomobject]@{
        title            = 'Pi'
        body             = 'Ready'
        routeVersion     = 1
        notificationId   = '11111111-1111-4111-8111-111111111111'
        notificationKind = 'turn-complete'
        originKind       = 'pi-web'
        instanceKey      = '22222222-2222-4222-8222-222222222222'
        routingKey       = ('a' * 64)
        cwdBase          = 'proj'
        tabTitle         = 'Pi - proj - #abc123def456'
    }
}

# --- Validation ---
Write-Host "`n== Resolve-NotifyExactRouteMetadata =="

$empty = Resolve-NotifyExactRouteMetadata -Payload $null
Assert-True (-not $empty.HasAnyRouteField) 'legacy-null-payload-no-route-fields'
Assert-True (-not $empty.IsValidPiWebExact) 'legacy-null-not-exact'

$legacy = Resolve-NotifyExactRouteMetadata -Payload ([pscustomobject]@{ title = 'x'; body = 'y'; cwdBase = 'z'; tabTitle = 't' })
Assert-True (-not $legacy.HasAnyRouteField) 'legacy-fields-only-not-route'
Assert-True (-not $legacy.IsValidPiWebExact) 'legacy-not-exact'

$valid = Resolve-NotifyExactRouteMetadata -Payload (New-ValidPiWebPayload)
Assert-True $valid.HasAnyRouteField 'valid-has-route-fields'
Assert-True $valid.IsValidPiWebExact 'valid-is-exact'
Assert-Equal 'pi-web' $valid.OriginKind 'valid-origin'
Assert-Equal '' $valid.InvalidReason 'valid-no-invalid-reason'

$opaqueInstance = New-ValidPiWebPayload
$opaqueInstance.instanceKey = 'piweb-prod_01'
$meta = Resolve-NotifyExactRouteMetadata -Payload $opaqueInstance
Assert-True $meta.IsValidPiWebExact 'opaque-instance-valid'
Assert-Equal '' $meta.InvalidReason 'opaque-instance-no-invalid-reason'

$badInstance = New-ValidPiWebPayload
$badInstance.instanceKey = 'bad/path'
$meta = Resolve-NotifyExactRouteMetadata -Payload $badInstance
Assert-True (-not $meta.IsValidPiWebExact) 'bad-instance-not-exact'
Assert-Equal 'instance-key' $meta.InvalidReason 'bad-instance-reason'

$badVersion = New-ValidPiWebPayload
$badVersion.routeVersion = 2
$meta = Resolve-NotifyExactRouteMetadata -Payload $badVersion
Assert-True (-not $meta.IsValidPiWebExact) 'bad-version-not-exact'
Assert-Equal 'route-version' $meta.InvalidReason 'bad-version-reason'

$badOrigin = New-ValidPiWebPayload
$badOrigin.originKind = 'browser'
$meta = Resolve-NotifyExactRouteMetadata -Payload $badOrigin
Assert-True (-not $meta.IsValidPiWebExact) 'bad-origin-not-exact'
Assert-Equal 'origin-kind' $meta.InvalidReason 'bad-origin-reason'

$badRouting = New-ValidPiWebPayload
$badRouting.routingKey = 'short'
$meta = Resolve-NotifyExactRouteMetadata -Payload $badRouting
Assert-True (-not $meta.IsValidPiWebExact) 'bad-routing-not-exact'
Assert-Equal 'routing-key' $meta.InvalidReason 'bad-routing-reason'

$terminal = [pscustomobject]@{
    routeVersion   = 1
    notificationId = '11111111-1111-4111-8111-111111111111'
    originKind     = 'terminal'
}
$meta = Resolve-NotifyExactRouteMetadata -Payload $terminal
Assert-True $meta.HasAnyRouteField 'terminal-has-fields'
Assert-True (-not $meta.IsValidPiWebExact) 'terminal-not-pi-web-exact'
Assert-Equal 'terminal' $meta.OriginKind 'terminal-origin'

# --- Fingerprint non-disclosure ---
Write-Host "`n== Fingerprint non-disclosure =="
$rawSession = 'session-raw-ABCDEF-should-never-appear'
$fp = Get-NotifyRouteFingerprint -Value $rawSession
Assert-True ($fp.Length -eq 16) 'fingerprint-length-16'
Assert-True ($fp -notmatch 'session') 'fingerprint-not-raw-substring'
Assert-True ($fp -ne $rawSession) 'fingerprint-not-equal-raw'
Assert-True ($fp -match '^[0-9a-f]{16}$') 'fingerprint-hex'

# --- Freeze decisions ---
Write-Host "`n== Freeze decision matrix =="

$ready = Get-NotifyRouteFreezeDecision -ClientResult ([pscustomobject]@{ Available = $true; Result = 'ready'; SnapshotId = 'snap-1'; Reason = '' }) -NotificationId 'n1'
Assert-Equal 'exact-ready' $ready.Decision 'freeze-ready-decision'
Assert-equal 'pi-web' $ready.OriginKind 'freeze-ready-origin'
Assert-equal 'snap-1' $ready.SnapshotId 'freeze-ready-snapshot'

$miss = Get-NotifyRouteFreezeDecision -ClientResult ([pscustomobject]@{ Available = $true; Result = 'miss'; SnapshotId = ''; Reason = '' }) -NotificationId 'n1'
Assert-Equal 'fail-closed' $miss.Decision 'freeze-miss-fail-closed'
Assert-Equal 'pi-web' $miss.OriginKind 'freeze-miss-keeps-origin'

$unavail = Get-NotifyRouteFreezeDecision -ClientResult ([pscustomobject]@{ Available = $false; Result = 'adapter-unavailable'; SnapshotId = ''; Reason = 'route-host-missing' }) -NotificationId 'n1'
Assert-Equal 'fail-closed' $unavail.Decision 'freeze-missing-host-fail-closed'
Assert-Equal 'pi-web' $unavail.OriginKind 'freeze-missing-host-keeps-origin'

$ownerUnresolved = Get-NotifyRouteFreezeDecision -ClientResult ([pscustomobject]@{ Available = $true; Result = 'owner-unresolved'; SnapshotId = ''; Reason = '' }) -NotificationId 'n1'
Assert-equal 'fail-closed' $ownerUnresolved.Decision 'freeze-owner-unresolved-fail-closed'
Assert-Equal 'pi-web' $ownerUnresolved.OriginKind 'freeze-owner-unresolved-keeps-origin'

foreach ($failResult in @('ambiguous', 'stale', 'replay', 'expired', 'protocol-mismatch', 'timeout', 'select-failed', 'foreground-denied', 'rejected')) {
    $d = Get-NotifyRouteFreezeDecision -ClientResult ([pscustomobject]@{ Available = $true; Result = $failResult; SnapshotId = ''; Reason = 'x' }) -NotificationId 'n1'
    Assert-Equal 'fail-closed' $d.Decision ("freeze-$failResult-fail-closed")
    Assert-equal 'pi-web' $d.OriginKind ("freeze-$failResult-keeps-origin")
}

# --- Activate decisions ---
Write-Host "`n== Activate decision matrix =="

$term = Get-NotifyRouteActivateDecision -OriginKind '' -NotificationId '' -SnapshotId ''
Assert-Equal 'terminal' $term.Decision 'activate-no-origin-is-terminal'

$handled = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $true; Result = 'session-url-confirmed'; Reason = '' })
Assert-equal 'handled' $handled.Decision 'activate-session-url-confirmed-handled'

$handled2 = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $true; Result = 'already-active'; Reason = '' })
Assert-equal 'handled' $handled2.Decision 'activate-already-active-handled'

$handled3 = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $true; Result = 'session-confirmed'; Reason = '' })
Assert-equal 'handled' $handled3.Decision 'activate-session-confirmed-handled'

$focused = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 'snapshot-focused-1' -ClientResult ([pscustomobject]@{
    Available = $true
    Result = 'pending'
    Reason = 'delivered-awaiting-result'
    SnapshotId = 'snapshot-focused-1'
    ActivationRequestId = 'activation-focused-1'
    ActivationPhase = 'desktop-row-focused-awaiting-proof'
})
Assert-Equal 'focused' $focused.Decision 'activate-desktop-focus-progress'
Assert-Equal 'pending' $focused.Result 'activate-desktop-focus-keeps-pending'
Assert-Equal 'background-proof-pending' $focused.Reason 'activate-desktop-focus-background-proof'

$focusedWrongSnapshot = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 'snapshot-focused-1' -ClientResult ([pscustomobject]@{
    Available = $true
    Result = 'pending'
    Reason = 'delivered-awaiting-result'
    SnapshotId = 'snapshot-focused-wrong'
    ActivationRequestId = 'activation-focused-1'
    ActivationPhase = 'desktop-row-focused-awaiting-proof'
})
Assert-Equal 'fail-closed' $focusedWrongSnapshot.Decision 'activate-focus-progress-requires-exact-snapshot'

$focusedMissingActivation = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 'snapshot-focused-1' -ClientResult ([pscustomobject]@{
    Available = $true
    Result = 'pending'
    Reason = 'delivered-awaiting-result'
    SnapshotId = 'snapshot-focused-1'
    ActivationRequestId = ''
    ActivationPhase = 'desktop-row-focused-awaiting-proof'
})
Assert-Equal 'fail-closed' $focusedMissingActivation.Decision 'activate-focus-progress-requires-activation-id'

$fallback = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $true; Result = 'miss'; Reason = '' })
Assert-equal 'fail-closed' $fallback.Decision 'activate-miss-fail-closed'

$fallback2 = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $false; Result = 'adapter-unavailable'; Reason = 'route-host-missing' })
Assert-equal 'fail-closed' $fallback2.Decision 'activate-unavailable-fail-closed'

foreach ($failResult in @('ambiguous', 'stale', 'replay', 'expired', 'protocol-mismatch', 'timeout', 'select-failed', 'foreground-denied')) {
    $d = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId 's1' -ClientResult ([pscustomobject]@{ Available = $true; Result = $failResult; Reason = 'x' })
    Assert-equal 'fail-closed' $d.Decision ("activate-$failResult-fail-closed")
}

$missingSnap = Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId 'n1' -SnapshotId ''
Assert-equal 'fail-closed' $missingSnap.Decision 'activate-missing-snapshot-fail-closed'

# --- Mock client end-to-end freeze/activate ---
Write-Host "`n== Mock client freeze/activate =="

$script:NotifyRouteHostClientMock = {
    param($Request, $WaitMs)
    $type = [string]$Request['type']
    if ($type -eq 'freeze') {
        return [pscustomobject]@{
            Available = $true
            ExitCode  = 0
            Result    = 'ready'
            Reason    = ''
            SnapshotId = 'snap-mock-001'
            ActivationRequestId = ''
            RawLength = 12
            TypeFingerprint = (Get-NotifyRouteFingerprint -Value 'freeze')
        }
    }
    if ($type -eq 'activate') {
        return [pscustomobject]@{
            Available = $true
            ExitCode  = 0
            Result    = 'session-url-confirmed'
            Reason    = ''
            SnapshotId = [string]$Request['snapshotId']
            ActivationRequestId = 'act-1'
            RawLength = 20
            TypeFingerprint = (Get-NotifyRouteFingerprint -Value 'activate')
        }
    }
    return [pscustomobject]@{ Available = $true; ExitCode = 1; Result = 'rejected'; Reason = 'unknown'; SnapshotId = ''; ActivationRequestId = ''; RawLength = 0; TypeFingerprint = '' }
}

$freeze = Invoke-NotifyExactRouteFreeze -NotificationId '11111111-1111-4111-8111-111111111111' -NotificationKind 'ask-user' -InstanceKey '22222222-2222-4222-8222-222222222222' -RoutingKey ('b' * 64)
Assert-equal 'exact-ready' $freeze.Decision 'mock-freeze-ready'
Assert-equal 'snap-mock-001' $freeze.SnapshotId 'mock-freeze-snapshot'

$activate = Invoke-NotifyExactRouteActivate -NotificationId '11111111-1111-4111-8111-111111111111' -SnapshotId 'snap-mock-001' -WaitMs 100 -TimeoutMs 500
Assert-equal 'handled' $activate.Decision.Decision 'mock-activate-handled'
Assert-equal 'session-url-confirmed' $activate.Decision.Result 'mock-activate-result'

$script:MockReturnOnProgress = $false
$script:MockActivationEnvelopeTtlMs = 0
$script:NotifyRouteHostClientMock = {
    param($Request, $WaitMs, $ReturnOnProgress)
    $script:MockReturnOnProgress = [bool]$ReturnOnProgress
    $script:MockActivationEnvelopeTtlMs = [long]$Request['expiresAtMs'] - [long]$Request['issuedAtMs']
    return [pscustomobject]@{
        Available = $true
        ExitCode  = 0
        Result    = 'pending'
        Reason    = 'delivered-awaiting-result'
        SnapshotId = [string]$Request['snapshotId']
        ActivationRequestId = 'activation-mock-focused'
        ActivationPhase = 'desktop-row-focused-awaiting-proof'
        RawLength = 20
        TypeFingerprint = (Get-NotifyRouteFingerprint -Value 'activate')
    }
}
$focusedActivate = Invoke-NotifyExactRouteActivate -NotificationId '11111111-1111-4111-8111-111111111111' -SnapshotId 'snapshot-mock-focused' -WaitMs 45000 -TimeoutMs 48000
Assert-True (-not $script:MockReturnOnProgress) 'mock-activate-does-not-request-progress-return'
Assert-Equal 5000 $script:MockActivationEnvelopeTtlMs 'mock-activate-keeps-short-transport-ttl'
Assert-Equal 'focused' $focusedActivate.Decision.Decision 'mock-activate-focused-defense'
Assert-Equal 'background-proof-pending' $focusedActivate.Decision.Reason 'mock-activate-focused-background-proof'

# Unavailable mock
$script:NotifyRouteHostClientMock = {
    param($Request, $WaitMs)
    return [pscustomobject]@{
        Available = $false
        ExitCode  = -1
        Result    = 'adapter-unavailable'
        Reason    = 'route-host-missing'
        SnapshotId = ''
        ActivationRequestId = ''
        RawLength = 0
        TypeFingerprint = ''
    }
}
$freezeDown = Invoke-NotifyExactRouteFreeze -NotificationId '11111111-1111-4111-8111-111111111111' -InstanceKey '22222222-2222-4222-8222-222222222222' -RoutingKey ('c' * 64)
Assert-Equal 'fail-closed' $freezeDown.Decision 'mock-freeze-unavailable-fail-closed'
Assert-Equal 'pi-web' $freezeDown.OriginKind 'mock-freeze-unavailable-keeps-origin'

$activateDown = Invoke-NotifyExactRouteActivate -NotificationId '11111111-1111-4111-8111-111111111111' -SnapshotId 'snap-x' -WaitMs 100 -TimeoutMs 500
Assert-equal 'fail-closed' $activateDown.Decision.Decision 'mock-activate-unavailable-fail-closed'

# Ambiguous mock
$script:NotifyRouteHostClientMock = {
    param($Request, $WaitMs)
    return [pscustomobject]@{
        Available = $true
        ExitCode  = 3
        Result    = 'ambiguous'
        Reason    = ''
        SnapshotId = ''
        ActivationRequestId = ''
        RawLength = 8
        TypeFingerprint = ''
    }
}
$freezeAmb = Invoke-NotifyExactRouteFreeze -NotificationId '11111111-1111-4111-8111-111111111111' -InstanceKey '22222222-2222-4222-8222-222222222222' -RoutingKey ('d' * 64)
Assert-equal 'fail-closed' $freezeAmb.Decision 'mock-freeze-ambiguous-fail-closed'
Assert-equal 'pi-web' $freezeAmb.OriginKind 'mock-freeze-ambiguous-keeps-origin'

$activateStale = Invoke-NotifyExactRouteActivate -NotificationId '11111111-1111-4111-8111-111111111111' -SnapshotId 'snap-x' -WaitMs 100 -TimeoutMs 500
# mock still returns ambiguous for activate type too
Assert-equal 'fail-closed' $activateStale.Decision.Decision 'mock-activate-ambiguous-fail-closed'

$script:NotifyRouteHostClientMock = $null

# --- Foreground auto-dismiss origin allowlist ---
# Mirrors the pure helper used by pi-notify-broker.ps1 and pi-notify-popup.ps1 so pure
# decision coverage does not require WinForms/UIAutomation. Keep semantics identical.
function Test-NotifyForegroundDismissAllowed {
    param([string]$OriginKind = '')

    $kind = if ($null -eq $OriginKind) { '' } else { $OriginKind.Trim() }
    return ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'terminal')
}

Write-Host "`n== Foreground dismiss origin allowlist =="
# Same tabTitle fixture intentionally reused: eligibility must ignore title/cwd content.
$sameTabTitle = 'pi - proj - #abc123def456'
Assert-True (Test-NotifyForegroundDismissAllowed -OriginKind 'terminal') 'dismiss-allowed-terminal'
Assert-True (Test-NotifyForegroundDismissAllowed -OriginKind '') 'dismiss-allowed-legacy-empty'
Assert-True (Test-NotifyForegroundDismissAllowed -OriginKind '  ') 'dismiss-allowed-legacy-whitespace'
Assert-True (Test-NotifyForegroundDismissAllowed) 'dismiss-allowed-legacy-omitted'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'pi-web')) 'dismiss-denied-pi-web'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'PI-WEB')) 'dismiss-denied-pi-web-case'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'browser')) 'dismiss-denied-unknown-browser'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'pi-web-desktop')) 'dismiss-denied-future-desktop'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'unknown')) 'dismiss-denied-unknown'
# Title presence must not override origin allowlist (reproduces the real bug fixture).
Assert-True (Test-NotifyForegroundDismissAllowed -OriginKind 'terminal') ('dismiss-allowed-terminal-same-title fixture={0}' -f $sameTabTitle)
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'pi-web')) ('dismiss-denied-pi-web-same-title fixture={0}' -f $sameTabTitle)

# --- Envelope shape ---
Write-Host "`n== Envelope =="
$envl = New-NotifyRouteRequestEnvelope -Type 'freeze' -Fields @{ notificationId = 'n'; instanceKey = 'i'; routingKey = 'r' } -TtlMs 5000
Assert-equal 1 $envl.protocolVersion 'envelope-protocol-version'
Assert-equal 'freeze' $envl.type 'envelope-type'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$envl.requestId)) 'envelope-request-id'
Assert-True ([int64]$envl.expiresAtMs -gt [int64]$envl.issuedAtMs) 'envelope-ttl-positive'

# --- Propagation payload shape (listener broker JSON fields) ---
Write-Host "`n== Propagation fields =="
$payloadTable = @{
    title = 't'
    body = 'b'
    focusTarget = 'h'
    cwdBase = 'c'
    tabTitle = 'tab'
    sessionName = 's'
    targetFingerprint = 'fp'
    stackIndex = 0
    timeoutSeconds = 10
    popupPlacement = 'cursor'
    originKind = 'pi-web'
    notificationId = '11111111-1111-4111-8111-111111111111'
    snapshotId = 'snap-1'
}
$json = $payloadTable | ConvertTo-Json -Depth 4 -Compress
Assert-True ($json -match 'originKind') 'payload-has-originKind'
Assert-True ($json -match 'notificationId') 'payload-has-notificationId'
Assert-True ($json -match 'snapshotId') 'payload-has-snapshotId'
Assert-True ($json -notmatch 'routingKey') 'payload-no-routingKey'
Assert-True ($json -notmatch 'instanceKey') 'payload-no-instanceKey'
Assert-True ($json -notmatch 'session-raw') 'payload-no-raw-session-marker'

$parsed = $json | ConvertFrom-Json
Assert-equal 'pi-web' $parsed.originKind 'roundtrip-origin'
Assert-equal 'snap-1' $parsed.snapshotId 'roundtrip-snapshot'
Assert-True (-not $parsed.PSObject.Properties['routingKey']) 'roundtrip-no-routingKey'
Assert-True (-not $parsed.PSObject.Properties['instanceKey']) 'roundtrip-no-instanceKey'

# --- Default exe path ---
Write-Host "`n== Route host exe resolution =="
$exe = Get-NotifyRouteHostExe
Assert-True ($exe -match 'PiNotifyRouteHost') 'default-exe-contains-name'


# --- Paseo payload / label / TTL / selection contracts ---
Write-Host "`n== Paseo route metadata =="

function New-ValidPaseoPayload {
    param(
        [string]$Kind = 'finished',
        [string]$ServerId = 'server-alpha',
        [string]$WorkspaceId = 'workspace-one',
        [string]$AgentId = 'agent-42'
    )
    return [pscustomobject]@{
        title            = 'Paseo agent'
        body             = 'done'
        originKind       = 'paseo'
        notificationId   = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        notificationKind = $Kind
        paseoRoute       = [pscustomobject]@{
            version     = 1
            serverId    = $ServerId
            workspaceId = $WorkspaceId
            agentId     = $AgentId
        }
    }
}

$paseoValid = Resolve-NotifyPaseoRouteMetadata -Payload (New-ValidPaseoPayload)
Assert-True $paseoValid.IsValidPaseoExact 'paseo-valid-exact'
Assert-equal 'paseo' $paseoValid.OriginKind 'paseo-valid-origin'
Assert-equal 'finished' $paseoValid.NotificationKind 'paseo-valid-kind'
Assert-equal '' $paseoValid.InvalidReason 'paseo-valid-reason'

$paseoPerm = Resolve-NotifyPaseoRouteMetadata -Payload (New-ValidPaseoPayload -Kind 'permission')
Assert-True $paseoPerm.IsValidPaseoExact 'paseo-permission-valid'

$paseoError = Resolve-NotifyPaseoRouteMetadata -Payload (New-ValidPaseoPayload -Kind 'error')
Assert-True (-not $paseoError.IsValidPaseoExact) 'paseo-error-rejected'
Assert-Equal 'notification-kind' $paseoError.InvalidReason 'paseo-error-reason'

$paseoBadVersion = New-ValidPaseoPayload
$paseoBadVersion.paseoRoute.version = 2
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoBadVersion
Assert-True (-not $meta.IsValidPaseoExact) 'paseo-bad-version-rejected'
Assert-equal 'route-version' $meta.InvalidReason 'paseo-bad-version-reason'

$paseoNonCanonicalVersion = New-ValidPaseoPayload
$paseoNonCanonicalVersion.paseoRoute.version = '01'
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoNonCanonicalVersion
Assert-True (-not $meta.IsValidPaseoExact) 'paseo-noncanonical-version-rejected'

$paseoNonStringId = New-ValidPaseoPayload
$paseoNonStringId.paseoRoute.serverId = [pscustomobject]@{ nested = 'not-an-id' }
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoNonStringId
Assert-True (-not $meta.IsValidPaseoExact) 'paseo-non-string-id-rejected'
Assert-equal 'server-id' $meta.InvalidReason 'paseo-non-string-id-reason'

$paseoOpaqueId = New-ValidPaseoPayload -ServerId 'server:alpha/path?opaque'
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoOpaqueId
Assert-True $meta.IsValidPaseoExact 'paseo-opaque-id-separators-accepted'

$paseoLongId = New-ValidPaseoPayload -ServerId ('s' * 257)
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoLongId
Assert-True (-not $meta.IsValidPaseoExact) 'paseo-overlong-server-rejected'
Assert-equal 'server-id' $meta.InvalidReason 'paseo-overlong-server-reason'

$paseoCtrl = New-ValidPaseoPayload -AgentId ("agent`twith-control")
$meta = Resolve-NotifyPaseoRouteMetadata -Payload $paseoCtrl
Assert-True (-not $meta.IsValidPaseoExact) 'paseo-control-char-rejected'

$paseoNoRoute = Resolve-NotifyPaseoRouteMetadata -Payload ([pscustomobject]@{ originKind = 'paseo'; notificationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; notificationKind = 'finished' })
Assert-True (-not $paseoNoRoute.IsValidPaseoExact) 'paseo-missing-route-rejected'

Assert-equal 'Paseo' (Get-NotifyAppLabel -OriginKind 'paseo') 'app-label-paseo'
Assert-equal 'Pi Remote' (Get-NotifyAppLabel -OriginKind 'pi-web') 'app-label-pi-web'
Assert-equal 'Pi Remote' (Get-NotifyAppLabel -OriginKind 'terminal') 'app-label-terminal'
Assert-equal 'Pi Remote' (Get-NotifyAppLabel -OriginKind '') 'app-label-empty'

Write-Host "`n== Paseo TTL and fingerprint =="
Assert-equal 1800 (Get-NotifyPaseoActivationTtlSeconds -PopupTimeoutSeconds 99999) 'paseo-ttl-hard-cap-30m'
Assert-equal 30 (Get-NotifyPaseoActivationTtlSeconds -PopupTimeoutSeconds 30) 'paseo-ttl-follows-popup'
Assert-equal 1800 (Get-NotifyPaseoActivationTtlSeconds -PopupTimeoutSeconds 0) 'paseo-ttl-default-when-missing'
Assert-equal 1800 (Get-NotifyPaseoActivationTtlSeconds -Config @{ popupTimeoutSeconds = 5000 }) 'paseo-ttl-config-capped'

$fp1 = Get-NotifyPaseoTargetFingerprint -ServerId 'srv' -AgentId 'ag'
$fp2 = Get-NotifyPaseoTargetFingerprint -ServerId 'srv' -AgentId 'ag'
$fp3 = Get-NotifyPaseoTargetFingerprint -ServerId 'srv' -AgentId 'other'
Assert-equal $fp1 $fp2 'paseo-fp-stable'
Assert-True ($fp1 -ne $fp3) 'paseo-fp-differs-by-agent'
Assert-equal 64 $fp1.Length 'paseo-fp-sha256-hex-length'

Write-Host "`n== Paseo target selection =="
# Dot-source controller for pure selection helpers without network.
. (Join-Path $scriptDir 'paseo-desktop-route.ps1')

$tExact = [pscustomobject]@{ ServerId = 's1'; AgentId = 'a1'; WorkspaceId = 'w1' }
$tServerOnly = [pscustomobject]@{ ServerId = 's1'; AgentId = 'other'; WorkspaceId = 'w1' }
$tOther = [pscustomobject]@{ ServerId = 's2'; AgentId = 'a9'; WorkspaceId = 'w9' }

$sel = Select-NotifyPaseoActivationTarget -Targets @($tExact, $tOther) -ServerId 's1' -AgentId 'a1'
Assert-True $sel.Ok 'select-exact-agent-ok'
Assert-equal 'exact-agent' $sel.Result 'select-exact-agent-result'

$tMultiPanel = [pscustomobject]@{
    ServerId = 's1'; AgentId = ''; WorkspaceId = 'w1'; SelectedAgentIds = @('a1', 'a2')
}
$sel = Select-NotifyPaseoActivationTarget -Targets @($tMultiPanel, $tOther) -ServerId 's1' -AgentId 'a2'
Assert-True $sel.Ok 'select-multi-panel-agent-ok'
Assert-equal 'exact-agent' $sel.Result 'select-multi-panel-agent-result'

$tSecondSelectedPanel = [pscustomobject]@{
    ServerId = 's1'; AgentId = 'other'; WorkspaceId = 'w2'; SelectedAgentIds = @('a2')
}
$sel = Select-NotifyPaseoActivationTarget -Targets @($tMultiPanel, $tSecondSelectedPanel) -ServerId 's1' -AgentId 'a2'
Assert-True (-not $sel.Ok) 'select-multi-panel-agent-ambiguous'
Assert-equal 'ambiguous' $sel.Result 'select-multi-panel-agent-ambiguous-result'

$sel = Select-NotifyPaseoActivationTarget -Targets @($tServerOnly, $tOther) -ServerId 's1' -AgentId 'a1'
Assert-True $sel.Ok 'select-exact-server-ok'
Assert-equal 'exact-server' $sel.Result 'select-exact-server-result'

$sel = Select-NotifyPaseoActivationTarget -Targets @($tExact, ([pscustomobject]@{ ServerId = 's1'; AgentId = 'a1'; WorkspaceId = 'w2' })) -ServerId 's1' -AgentId 'a1'
Assert-True (-not $sel.Ok) 'select-ambiguous-exact-agent'
Assert-equal 'ambiguous' $sel.Result 'select-ambiguous-result'

$sel = Select-NotifyPaseoActivationTarget -Targets @($tServerOnly, ([pscustomobject]@{ ServerId = 's1'; AgentId = 'x'; WorkspaceId = 'w3' })) -ServerId 's1' -AgentId 'a1'
Assert-True (-not $sel.Ok) 'select-ambiguous-exact-server'
Assert-equal 'ambiguous' $sel.Result 'select-ambiguous-server-result'

$sel = Select-NotifyPaseoActivationTarget -Targets @($tOther) -ServerId 's1' -AgentId 'a1'
Assert-True (-not $sel.Ok) 'select-missing'
Assert-equal 'target-missing' $sel.Result 'select-missing-result'

Assert-True (Test-NotifyPaseoLoopbackAddress -Address '127.0.0.1') 'loopback-v4'
Assert-True (Test-NotifyPaseoLoopbackAddress -Address '::1') 'loopback-v6'
Assert-True (Test-NotifyPaseoLoopbackAddress -Address '[::1]') 'loopback-v6-bracketed-uri-host'
Assert-True (-not (Test-NotifyPaseoLoopbackAddress -Address '192.168.1.10')) 'non-loopback-rejected'
Assert-True (-not (Test-NotifyPaseoLoopbackAddress -Address '0.0.0.0')) 'zero-addr-rejected'
Assert-True (-not (Test-NotifyPaseoLoopbackAddress -Address '127.0.0.2')) 'non-canonical-loopback-rejected'

$trustedTarget = [pscustomobject]@{ id = 'page-1'; type = 'page'; url = 'paseo://app/h/server-alpha'; title = 'Paseo'; webSocketDebuggerUrl = 'ws://127.0.0.1:29318/devtools/page/page-1' }
Assert-True (Test-NotifyPaseoTrustedPageTarget -Target $trustedTarget -Port 29318) 'trusted-page-target'
$foreignTarget = [pscustomobject]@{ id = 'page-2'; type = 'page'; url = 'https://example.invalid/paseo'; title = 'Paseo'; webSocketDebuggerUrl = 'ws://127.0.0.1:29318/devtools/page/page-2' }
Assert-True (-not (Test-NotifyPaseoTrustedPageTarget -Target $foreignTarget -Port 29318)) 'title-substring-not-trusted'
$wrongPortTarget = [pscustomobject]@{ id = 'page-3'; type = 'page'; url = 'paseo://app/h/server-alpha'; title = 'Paseo'; webSocketDebuggerUrl = 'ws://127.0.0.1:29319/devtools/page/page-3' }
Assert-True (-not (Test-NotifyPaseoTrustedPageTarget -Target $wrongPortTarget -Port 29318)) 'target-websocket-port-must-match'
$mismatchedPageTarget = [pscustomobject]@{ id = 'page-4'; type = 'page'; url = 'paseo://app/h/server-alpha'; title = 'Paseo'; webSocketDebuggerUrl = 'ws://127.0.0.1:29318/devtools/page/other-page' }
Assert-True (-not (Test-NotifyPaseoTrustedPageTarget -Target $mismatchedPageTarget -Port 29318)) 'target-websocket-page-id-must-match'

$probeExpr = New-NotifyPaseoCdpEvaluateExpression -Mode probe
Assert-True ($probeExpr -notmatch 'Page\.navigate') 'probe-no-page-navigate'
Assert-True ($probeExpr -notmatch 'paseo://') 'probe-no-paseo-url'
$dispatchExpr = New-NotifyPaseoCdpEvaluateExpression -Mode dispatch -ServerId 's' -WorkspaceId 'w' -AgentId 'a'
Assert-True ($dispatchExpr -match 'paseo:web-notification-click') 'dispatch-uses-existing-event'
Assert-True ($dispatchExpr -notmatch 'Page\.navigate') 'dispatch-no-page-navigate'
Assert-True ($dispatchExpr -notmatch 'paseo://') 'dispatch-no-paseo-url'
Assert-True ($dispatchExpr -match 'atob\(') 'dispatch-base64-payload'

Write-Host "`n== Paseo activation state machine =="
# Prefer an isolated temp base so tests never touch the real user runtime dir.
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('paseo-route-test-' + [Guid]::NewGuid().ToString('N'))
$tempConfig = Join-Path $tempBase 'config.json'
New-Item -ItemType Directory -Force -Path $tempBase | Out-Null
try {
    $cfg = Ensure-NotifyBridgeConfig -ConfigPath $tempConfig -Port 23118
    Assert-True (-not [bool]$cfg.PaseoDesktopRoutingEnabled) 'paseo-routing-default-disabled'
    Assert-equal 29318 ([int]$cfg.PaseoCdpPort) 'paseo-cdp-default-port'

    # Ensure returns the same safe boolean semantics later used by install/check projection.
    $leaseConfig = Get-Content -Raw -LiteralPath $tempConfig | ConvertFrom-Json
    $leaseConfig | Add-Member -NotePropertyName 'paseoLeaseGateEnabled' -NotePropertyValue 'false'
    $leaseConfig | Add-Member -NotePropertyName 'paseoLeasePath' -NotePropertyValue '/tmp/paseo-sender-health.json'
    [System.IO.File]::WriteAllText($tempConfig, ($leaseConfig | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $cfg = Ensure-NotifyBridgeConfig -ConfigPath $tempConfig
    Assert-True (-not [bool]$cfg.PaseoLeaseGateEnabled) 'paseo-lease-gate-string-false-safe'
    Assert-equal '/tmp/paseo-sender-health.json' ([string]$cfg.PaseoLeasePath) 'paseo-lease-path-returned'
    $leaseConfig = Get-Content -Raw -LiteralPath $tempConfig | ConvertFrom-Json
    $leaseConfig.paseoLeaseGateEnabled = 'true'
    [System.IO.File]::WriteAllText($tempConfig, ($leaseConfig | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $cfg = Ensure-NotifyBridgeConfig -ConfigPath $tempConfig
    Assert-True ([bool]$cfg.PaseoLeaseGateEnabled) 'paseo-lease-gate-string-true-safe'

    $activationId = [Guid]::NewGuid().ToString('N')
    $saved = $null
    $dpapiOk = $true
    try {
        $saved = Save-NotifyPaseoActivationState -ActivationId $activationId -NotificationId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -NotificationKind 'finished' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60
    }
    catch {
        $dpapiOk = $false
    }

    if ($dpapiOk -and $null -ne $saved) {
        $read = Resolve-NotifyPaseoActivationState -ActivationId $activationId
        Assert-True $read.Available 'paseo-activation-read-available'
        Assert-equal 'ready' $read.State 'paseo-activation-ready'
        Assert-equal 'server-alpha' $read.ServerId 'paseo-activation-server'
        Assert-equal 'workspace-one' $read.WorkspaceId 'paseo-activation-workspace'
        Assert-equal 'agent-42' $read.AgentId 'paseo-activation-agent'

        $lease1 = Acquire-NotifyPaseoActivationLease -ActivationId $activationId -LeaseSeconds 30
        Assert-True $lease1.Acquired 'paseo-lease-first-ok'
        $lease2 = Acquire-NotifyPaseoActivationLease -ActivationId $activationId -LeaseSeconds 30
        Assert-True (-not $lease2.Acquired) 'paseo-lease-second-busy'
        Assert-equal 'busy' $lease2.Result 'paseo-lease-busy-result'
        Assert-True (-not (Release-NotifyPaseoActivationLease -ActivationId $activationId -LeaseId ([Guid]::NewGuid().ToString('N')))) 'paseo-wrong-owner-cannot-release'

        [void](Release-NotifyPaseoActivationLease -ActivationId $activationId -LeaseId $lease1.LeaseId)
        $afterRelease = Resolve-NotifyPaseoActivationState -ActivationId $activationId
        Assert-True $afterRelease.Available 'paseo-after-release-available'
        Assert-equal 'ready' $afterRelease.State 'paseo-after-release-ready'

        $lease3 = Acquire-NotifyPaseoActivationLease -ActivationId $activationId -LeaseSeconds 30
        Assert-True $lease3.Acquired 'paseo-lease-reacquire-ok'
        Assert-True (-not (Consume-NotifyPaseoActivationState -ActivationId $activationId -LeaseId ([Guid]::NewGuid().ToString('N')))) 'paseo-wrong-owner-cannot-consume'
        [void](Consume-NotifyPaseoActivationState -ActivationId $activationId -LeaseId $lease3.LeaseId)
        $afterConsume = Resolve-NotifyPaseoActivationState -ActivationId $activationId
        Assert-True (-not $afterConsume.Available) 'paseo-consumed-missing'

        # Disabled routing remains retryable for a valid, unconsumed activation.
        $disabledId = [Guid]::NewGuid().ToString('N')
        [void](Save-NotifyPaseoActivationState -ActivationId $disabledId -NotificationId 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff' -NotificationKind 'finished' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60)
        $disabled = Invoke-NotifyPaseoRouteActivate -ActivationId $disabledId -Config @{ paseoDesktopRoutingEnabled = $false } -TimeoutMs 100
        Assert-equal 'fail-closed' $disabled.Decision 'paseo-disabled-fail-closed'
        Assert-equal 'disabled' $disabled.Result 'paseo-disabled-result'
        Assert-equal 'paseo' $disabled.OriginKind 'paseo-disabled-origin-preserved'
        Assert-True (Resolve-NotifyPaseoActivationState -ActivationId $disabledId).Available 'paseo-disabled-not-consumed'

        $expiredId = [Guid]::NewGuid().ToString('N')
        [void](Save-NotifyPaseoActivationState -ActivationId $expiredId -NotificationId 'cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa' -NotificationKind 'finished' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60)
        $expiredPayload = Read-NotifyPaseoActivationPayload -ActivationId $expiredId
        $expiredPayload.expiresAtTicks = 1
        [void](Write-NotifyPaseoActivationPayload -ActivationId $expiredId -Payload $expiredPayload)
        $expired = Resolve-NotifyPaseoActivationState -ActivationId $expiredId
        Assert-True (-not $expired.Available) 'paseo-expired-unavailable'
        Assert-equal 'expired' $expired.Result 'paseo-expired-result'
    }
    else {
        Write-Host 'SKIP  paseo-dpapi-state-machine (ProtectedData unavailable on this host)'
    }
}
finally {
    try { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}


Write-Host "`n== Paseo close request and tombstone =="
$closeValid = Resolve-NotifyPaseoCloseRequest -Payload ([pscustomobject]@{
    originKind = 'paseo'
    version = 1
    notificationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
})
Assert-True $closeValid.IsValid 'paseo-close-valid'
Assert-equal '1' $closeValid.Version 'paseo-close-version'

$closeBadOrigin = Resolve-NotifyPaseoCloseRequest -Payload ([pscustomobject]@{
    originKind = 'pi-web'
    version = 1
    notificationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
})
Assert-True (-not $closeBadOrigin.IsValid) 'paseo-close-rejects-non-paseo'
Assert-equal 'origin-kind' $closeBadOrigin.InvalidReason 'paseo-close-bad-origin-reason'

$closeBadUuid = Resolve-NotifyPaseoCloseRequest -Payload ([pscustomobject]@{
    originKind = 'paseo'
    version = 1
    notificationId = 'not-a-uuid'
})
Assert-True (-not $closeBadUuid.IsValid) 'paseo-close-rejects-bad-uuid'
Assert-equal 'notification-id' $closeBadUuid.InvalidReason 'paseo-close-bad-uuid-reason'

$closeWithRoute = Resolve-NotifyPaseoCloseRequest -Payload ([pscustomobject]@{
    originKind = 'paseo'
    version = 1
    notificationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    serverId = 'should-not-be-here'
})
Assert-True (-not $closeWithRoute.IsValid) 'paseo-close-rejects-route-fields'
Assert-equal 'unexpected-field' $closeWithRoute.InvalidReason 'paseo-close-unexpected-field-reason'

$closeWithBenignExtra = Resolve-NotifyPaseoCloseRequest -Payload ([pscustomobject]@{
    originKind = 'paseo'
    version = 1
    notificationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    clientVersion = '1.0'
})
Assert-True (-not $closeWithBenignExtra.IsValid) 'paseo-close-rejects-benign-extra-field'
Assert-equal 'unexpected-field' $closeWithBenignExtra.InvalidReason 'paseo-close-benign-extra-reason'

$fpOld = Get-NotifyPaseoNotificationFingerprint -NotificationId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
$fpNew = Get-NotifyPaseoNotificationFingerprint -NotificationId 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
Assert-equal 64 $fpOld.Length 'paseo-close-fp-length'
Assert-True ($fpOld -ne $fpNew) 'paseo-close-fp-differs-by-uuid'
Assert-True ((Get-NotifyPaseoCloseEventName -NotificationFingerprint $fpOld) -match '^Local\\PiRemotePaseoClose_[0-9a-f]{64}$') 'paseo-close-event-name'

Write-Host "`n== Paseo health schema and readiness =="
$flagsOk = Test-NotifyPaseoPersistedElectronFlags -Port 29318 -Flags '--remote-debugging-port=29318 --remote-debugging-address=127.0.0.1'
Assert-True $flagsOk.Ok 'paseo-flags-exact-ok'
$flagsBadHost = Test-NotifyPaseoPersistedElectronFlags -Port 29318 -Flags '--remote-debugging-port=29318 --remote-debugging-address=0.0.0.0'
Assert-True (-not $flagsBadHost.Ok) 'paseo-flags-non-loopback-rejected'
$flagsBadPort = Test-NotifyPaseoPersistedElectronFlags -Port 29318 -Flags '--remote-debugging-port=23118 --remote-debugging-address=127.0.0.1'
Assert-True (-not $flagsBadPort.Ok) 'paseo-flags-wrong-port-rejected'
$flagsMissing = Test-NotifyPaseoPersistedElectronFlags -Port 29318 -Flags ''
Assert-True (-not $flagsMissing.Ok) 'paseo-flags-missing-rejected'

$displayPopup = Get-NotifyPaseoDisplayReadyState -DisplayMode 'popup-focus'
Assert-True $displayPopup.Ready 'paseo-display-popup-ready-when-script-present'
$displayToast = Get-NotifyPaseoDisplayReadyState -DisplayMode 'system-toast'
Assert-True $displayToast.Ready 'paseo-display-system-toast-ready'

# Source-isolated owner/target probes cover Windows-only branches without live CDP.
$ownerAbsent = Get-NotifyPaseoCdpOwnerSnapshot -Port 29318 -ConnectionProbe { param($Port) @() }
Assert-equal 'no-listener' $ownerAbsent.Reason 'paseo-owner-proven-empty-listener'
$ownerAbsentState = Get-NotifyPaseoCdpOwnerReadyState -Owner $ownerAbsent
Assert-True $ownerAbsentState.Ready 'paseo-owner-app-absent-ready'
Assert-equal 'app-absent' $ownerAbsentState.RouteState 'paseo-owner-app-absent-state'

$ownerProbeError = Get-NotifyPaseoCdpOwnerSnapshot -Port 29318 -ConnectionProbe { param($Port) throw 'probe denied' }
Assert-equal 'probe-error' $ownerProbeError.Result 'paseo-owner-probe-error-fail-closed'
Assert-True (-not (Get-NotifyPaseoCdpOwnerReadyState -Owner $ownerProbeError).Ready) 'paseo-owner-probe-error-not-app-absent'

$ownerNonLoopback = Get-NotifyPaseoCdpOwnerSnapshot -Port 29318 -ConnectionProbe {
    param($Port)
    @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = $Port; OwningProcess = 42 })
}
Assert-equal 'non-loopback' $ownerNonLoopback.Result 'paseo-owner-non-loopback'

$ownerForeign = Get-NotifyPaseoCdpOwnerSnapshot -Port 29318 -ConnectionProbe {
    param($Port)
    @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = $Port; OwningProcess = 42 })
} -ProcessProbe {
    param($ProcessId)
    [pscustomobject]@{ ProcessName = 'chrome'; Path = 'C:\foreign\chrome.exe' }
}
Assert-equal 'foreign-owner' $ownerForeign.Result 'paseo-owner-foreign-process'

$trustedTargetResponse = [pscustomobject]@{ Ok = $true; Targets = @($trustedTarget); Reason = '' }
$trustedTargetState = Get-NotifyPaseoCdpTargetReadyState -Response $trustedTargetResponse -Port 29318
Assert-True $trustedTargetState.Ready 'paseo-health-live-target-wrapper-ready'
Assert-equal 'ready' $trustedTargetState.RouteState 'paseo-health-live-target-wrapper-state'
$malformedTargetState = Get-NotifyPaseoCdpTargetReadyState -Response ([pscustomobject]@{ Ok = $true }) -Port 29318
Assert-True (-not $malformedTargetState.Ready) 'paseo-health-malformed-target-fail-closed'
Assert-equal 'malformed' $malformedTargetState.RouteState 'paseo-health-malformed-target-state'
$unavailableTargetState = Get-NotifyPaseoCdpTargetReadyState -Response ([pscustomobject]@{ Ok = $false; Targets = @(); Reason = 'cdp-unavailable' }) -Port 29318
Assert-True (-not $unavailableTargetState.Ready) 'paseo-health-target-probe-unavailable-fail-closed'

$disabledRoute = Get-NotifyPaseoRouteReadyState -Config @{ paseoDesktopRoutingEnabled = $false; paseoCdpPort = 29318; Port = 23118; BrokerPort = 23119 }
Assert-True (-not $disabledRoute.Ready) 'paseo-route-disabled-not-ready'
Assert-equal 'disabled' $disabledRoute.RouteState 'paseo-route-disabled-state'

$conflictRoute = Get-NotifyPaseoRouteReadyState -Config @{ paseoDesktopRoutingEnabled = $true; paseoCdpPort = 23118; Port = 23118; BrokerPort = 23119 }
Assert-True (-not $conflictRoute.Ready) 'paseo-route-port-conflict-not-ready'
Assert-equal 'config-invalid' $conflictRoute.RouteState 'paseo-route-port-conflict-state'

$healthDisabled = Get-NotifyPaseoHealthSnapshot -Config @{ paseoDesktopRoutingEnabled = $false; paseoCdpPort = 29318; Port = 23118; BrokerPort = 23119 } -DisplayMode 'popup-focus'
Assert-True $healthDisabled.listenerReady 'paseo-health-listener-ready'
Assert-True $healthDisabled.displayReady 'paseo-health-display-ready'
Assert-True (-not $healthDisabled.routeReady) 'paseo-health-route-not-ready-when-disabled'
Assert-True (-not $healthDisabled.ready) 'paseo-health-ready-false-when-disabled'
Assert-equal 'disabled' $healthDisabled.routeState 'paseo-health-route-state-disabled'
Assert-True $healthDisabled.capabilities.notifyV1 'paseo-health-cap-notify'
Assert-True $healthDisabled.capabilities.closeV1 'paseo-health-cap-close'
Assert-True $healthDisabled.capabilities.existingClickEventV1 'paseo-health-cap-click'

$healthJson = ConvertTo-NotifyPaseoHealthJson -Snapshot $healthDisabled
Assert-True ($healthJson -match '"version"\s*:\s*1') 'paseo-health-json-version'
Assert-True ($healthJson -match '"routeState"\s*:\s*"disabled"') 'paseo-health-json-route-state'
Assert-True ($healthJson -match '"notifyV1"\s*:\s*true') 'paseo-health-json-cap-notify'
Assert-True ($healthJson -match '"closeV1"\s*:\s*true') 'paseo-health-json-cap-close'
Assert-True ($healthJson -match '"existingClickEventV1"\s*:\s*true') 'paseo-health-json-cap-click'
Assert-True ($healthJson -notmatch 'token|X-Pi-Notify|127\.0\.0\.1:|paseo://|notificationId|serverId|workspaceId|agentId|"title"|"body"|webSocketDebuggerUrl') 'paseo-health-json-no-secrets'

# Isolated tombstone/revoke race tests under temp base.
$tempCloseBase = Join-Path ([System.IO.Path]::GetTempPath()) ('paseo-close-test-' + [Guid]::NewGuid().ToString('N'))
$tempCloseConfig = Join-Path $tempCloseBase 'config.json'
New-Item -ItemType Directory -Force -Path $tempCloseBase | Out-Null
try {
    $null = Ensure-NotifyBridgeConfig -ConfigPath $tempCloseConfig -Port 23118
    $oldId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $newId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    Assert-True (-not (Test-NotifyPaseoCloseTombstone -NotificationId $oldId)) 'paseo-tombstone-absent-initially'

    # Corrupt/partial/tampered markers never suppress and are cleaned.
    $corruptId = 'cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa'
    [void](Save-NotifyPaseoCloseTombstone -NotificationId $corruptId -TtlSeconds 60)
    $corruptFp = Get-NotifyPaseoNotificationFingerprint -NotificationId $corruptId
    $corruptPath = Get-NotifyPaseoCloseTombstonePath -NotificationFingerprint $corruptFp
    [System.IO.File]::WriteAllText($corruptPath, '{"version":1}', [System.Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-NotifyPaseoCloseTombstone -NotificationId $corruptId)) 'paseo-tombstone-partial-does-not-suppress'
    Assert-True (-not (Test-Path -LiteralPath $corruptPath)) 'paseo-tombstone-partial-cleaned'

    [void](Save-NotifyPaseoCloseTombstone -NotificationId $corruptId -TtlSeconds 60)
    $tampered = [System.IO.File]::ReadAllText($corruptPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $tampered.fingerprint = Get-NotifyPaseoNotificationFingerprint -NotificationId $newId
    [System.IO.File]::WriteAllText($corruptPath, ($tampered | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-NotifyPaseoCloseTombstone -NotificationId $corruptId)) 'paseo-tombstone-fingerprint-mismatch-does-not-suppress'

    $signalId = 'dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb'
    [void](Save-NotifyPaseoCloseTombstone -NotificationId $signalId -TtlSeconds 60)
    $activationInProgress = $true
    Assert-True (Test-NotifyPaseoCloseSignal -NotificationId $signalId) 'paseo-close-signal-visible-during-activation'
    Assert-True $activationInProgress 'paseo-close-signal-does-not-depend-on-activation-state'

    $savedOld = $null
    $savedNew = $null
    $dpapiOk = $true
    try {
        $savedOld = Save-NotifyPaseoActivationState -ActivationId ([Guid]::NewGuid().ToString('N')) -NotificationId $oldId -NotificationKind 'permission' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60
        $savedNew = Save-NotifyPaseoActivationState -ActivationId ([Guid]::NewGuid().ToString('N')) -NotificationId $newId -NotificationKind 'permission' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60
    }
    catch {
        $dpapiOk = $false
    }

    if ($dpapiOk -and $null -ne $savedOld -and $null -ne $savedNew) {
        # Toast pointer cache uses the same protected notification UUID and must close exactly.
        $pointerDir = Get-NotifyBridgeLogDir
        New-Item -ItemType Directory -Force -Path $pointerDir | Out-Null
        $oldPointerPath = Join-Path $pointerDir ('activation-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        $newPointerPath = Join-Path $pointerDir ('activation-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        $pointerBase = @{ originKind = 'paseo'; expiresAtTicks = [DateTime]::UtcNow.AddSeconds(60).Ticks }
        $oldPointer = $pointerBase.Clone()
        $oldPointer['protectedNotificationId'] = Protect-NotifyBridgeValue -Value $oldId
        $newPointer = $pointerBase.Clone()
        $newPointer['protectedNotificationId'] = Protect-NotifyBridgeValue -Value $newId
        [System.IO.File]::WriteAllText($oldPointerPath, ($oldPointer | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($newPointerPath, ($newPointer | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))

        $closeOld = Invoke-NotifyPaseoCloseByNotificationId -NotificationId $oldId -Config @{ popupTimeoutSeconds = 60 }
        Assert-True $closeOld.Ok 'paseo-close-old-ok'
        Assert-equal 'ok' $closeOld.Result 'paseo-close-old-result'
        Assert-True (Test-NotifyPaseoCloseTombstone -NotificationId $oldId) 'paseo-tombstone-old-present'
        Assert-True (-not (Test-NotifyPaseoCloseTombstone -NotificationId $newId)) 'paseo-tombstone-new-absent'
        Assert-True (-not (Test-Path -LiteralPath $oldPointerPath)) 'paseo-close-revokes-exact-toast-pointer'
        Assert-True (Test-Path -LiteralPath $newPointerPath) 'paseo-close-old-preserves-new-toast-pointer'

        # Closing an already-missing id remains idempotent ok.
        $closeAgain = Invoke-NotifyPaseoCloseByNotificationId -NotificationId $oldId -Config @{ popupTimeoutSeconds = 60 }
        Assert-True $closeAgain.Ok 'paseo-close-idempotent-ok'

        # A close that wins the race prevents a later activation cache resurrection.
        $racedActivationId = [Guid]::NewGuid().ToString('N')
        $racedSave = Save-NotifyPaseoActivationUnlessClosed -ActivationId $racedActivationId -NotificationId $oldId -NotificationKind 'permission' -ServerId 'server-alpha' -WorkspaceId 'workspace-one' -AgentId 'agent-42' -TtlSeconds 60
        Assert-equal 'closed' $racedSave.Result 'paseo-close-wins-notify-race'
        Assert-True (-not (Resolve-NotifyPaseoActivationState -ActivationId $racedActivationId).Available) 'paseo-close-race-does-not-create-activation'

        # Exact old close must not revoke a newer same-agent activation.
        $stillNew = $false
        $dir = Get-NotifyPaseoActivationCacheDir
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $payload = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                $state = ConvertFrom-NotifyPaseoActivationPayload -Payload $payload -ActivationId ''
                if ($state.Available -and [string]$state.NotificationId -eq $newId) { $stillNew = $true }
            } catch {}
        }
        Assert-True $stillNew 'paseo-close-old-does-not-revoke-new'

        # Notify after close hits tombstone contract helper.
        Assert-True (Test-NotifyPaseoCloseTombstone -NotificationId $oldId) 'paseo-notify-after-close-dedup-helper'
    }
    else {
        Write-Host 'SKIP  paseo-close-tombstone-dpapi (ProtectedData unavailable on this host)'
    }
}
finally {
    try { Remove-Item -LiteralPath $tempCloseBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host "`n== Paseo foreground dismiss deny =="
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'paseo')) 'dismiss-denied-paseo'
Assert-True (-not (Test-NotifyForegroundDismissAllowed -OriginKind 'PASEO')) 'dismiss-denied-paseo-case'

Write-Host "`n== Paseo built-in notification helper (temp HKCU only) =="
$builtInHelper = Join-Path $scriptDir 'set-paseo-built-in-notifications.ps1'
Assert-True (Test-Path -LiteralPath $builtInHelper -PathType Leaf) 'paseo-built-in-helper-present'
$builtInSource = [System.IO.File]::ReadAllText($builtInHelper, [System.Text.UTF8Encoding]::new($false))
Assert-True ($builtInSource -match 'electron\.app\.Paseo') 'paseo-built-in-production-key'
Assert-True ($builtInSource -match 'paseo-built-in-notification-state\.json') 'paseo-built-in-state-name'
Assert-True ($builtInSource -match '\[NullString\]::Value') 'paseo-built-in-nullstring-replace'
Assert-True ($builtInSource -notmatch '(?i)(New-ItemProperty|Get-Item|Remove-ItemProperty)[^\r\n]*(HKLM:|HKEY_LOCAL_MACHINE)') 'paseo-built-in-no-hklm-operations'
Assert-True ($builtInSource -match 'RegistryPath and StatePath test overrides must be provided together') 'paseo-built-in-paired-overrides'
Assert-True ($builtInSource -match 'backup belongs to a different registry path') 'paseo-built-in-backup-path-bound'
Assert-True ($builtInSource -notmatch 'systemctl|ssh ') 'paseo-built-in-no-service-ssh'

$registryProviderAvailable = $false
try {
    $null = Get-PSDrive -Name HKCU -ErrorAction Stop
    $registryProviderAvailable = $true
}
catch {
    $registryProviderAvailable = $false
}

if (-not $registryProviderAvailable) {
    Write-Host 'SKIP  paseo-built-in-disable-restore-matrix (HKCU provider unavailable on this host)'
}
else {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-paseo-built-in-' + [Guid]::NewGuid().ToString('N'))
    $tempStateDir = Join-Path $tempRoot 'state'
    New-Item -ItemType Directory -Force -Path $tempStateDir | Out-Null
    $tempKeyLeaf = 'PiNotifyPaseoBuiltInTest-' + [Guid]::NewGuid().ToString('N')
    $tempRegistryPath = 'HKCU:\Software\PiNotifyTests\' + $tempKeyLeaf
    $tempOtherRegistryPath = $tempRegistryPath + '-Other'
    $tempStatePath = Join-Path $tempStateDir 'paseo-built-in-notification-state.json'

    function Invoke-NotifyPaseoBuiltInHelper {
        param(
            [Parameter(Mandatory = $true)][ValidateSet('Disable', 'Restore')]$Action,
            [Parameter(Mandatory = $true)][string]$RegistryPath,
            [Parameter(Mandatory = $true)][string]$StatePath
        )
        $ok = $false
        $errorText = ''
        try {
            if ($Action -eq 'Disable') {
                & $builtInHelper -Disable -Force -RegistryPath $RegistryPath -StatePath $StatePath | Out-Null
            }
            else {
                & $builtInHelper -Restore -Force -RegistryPath $RegistryPath -StatePath $StatePath | Out-Null
            }
            $ok = $true
        }
        catch {
            $errorText = [string]$_.Exception.Message
            $ok = $false
        }
        return [pscustomobject]@{
            Ok = $ok
            Error = $errorText
        }
    }

    function Get-NotifyPaseoBuiltInEnabledSnapshot {
        param([Parameter(Mandatory = $true)][string]$RegistryPath)
        if (-not (Test-Path -LiteralPath $RegistryPath)) {
            return [pscustomobject]@{ KeyExists = $false; HadEnabled = $false; EnabledValue = $null }
        }
        $item = Get-Item -LiteralPath $RegistryPath
        $names = @($item.GetValueNames())
        $had = $names -contains 'Enabled'
        $value = $null
        if ($had) { $value = [int]$item.GetValue('Enabled') }
        return [pscustomobject]@{ KeyExists = $true; HadEnabled = $had; EnabledValue = $value }
    }

    try {
        # Reject HKLM overrides without mutating anything.
        $hklm = Invoke-NotifyPaseoBuiltInHelper -Action Disable -RegistryPath 'HKLM:\Software\PiNotifyForbidden' -StatePath $tempStatePath
        Assert-True (-not $hklm.Ok) 'paseo-built-in-reject-hklm'

        # Restore with no backup must fail closed.
        if (Test-Path -LiteralPath $tempRegistryPath) { Remove-Item -LiteralPath $tempRegistryPath -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempStatePath) { Remove-Item -LiteralPath $tempStatePath -Force -ErrorAction SilentlyContinue }
        New-Item -Path $tempRegistryPath -Force | Out-Null
        New-ItemProperty -LiteralPath $tempRegistryPath -Name 'Enabled' -PropertyType DWord -Value 1 -Force | Out-Null
        $noBackup = Invoke-NotifyPaseoBuiltInHelper -Action Restore -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True (-not $noBackup.Ok) 'paseo-built-in-restore-no-backup-fails'
        $stillOne = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempRegistryPath
        Assert-True ($stillOne.HadEnabled -and [int]$stillOne.EnabledValue -eq 1) 'paseo-built-in-restore-no-backup-registry-unchanged'

        # Disable with original Enabled=1: backup once, write 0, second Disable keeps original backup.
        $disable1 = Invoke-NotifyPaseoBuiltInHelper -Action Disable -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True $disable1.Ok 'paseo-built-in-disable-ok'
        $afterDisable = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempRegistryPath
        Assert-True ($afterDisable.HadEnabled -and [int]$afterDisable.EnabledValue -eq 0) 'paseo-built-in-disable-sets-zero'
        Assert-True (Test-Path -LiteralPath $tempStatePath -PathType Leaf) 'paseo-built-in-backup-created'
        $backup1 = Get-Content -Raw -LiteralPath $tempStatePath | ConvertFrom-Json
        Assert-True ([bool]$backup1.hadEnabled -eq $true) 'paseo-built-in-backup-had-enabled'
        Assert-True ([int]$backup1.enabledValue -eq 1) 'paseo-built-in-backup-value-one'
        Assert-equal $tempRegistryPath ([string]$backup1.registryPath) 'paseo-built-in-backup-registry-bound'

        $disable2 = Invoke-NotifyPaseoBuiltInHelper -Action Disable -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True $disable2.Ok 'paseo-built-in-disable-idempotent'
        $backup2 = Get-Content -Raw -LiteralPath $tempStatePath | ConvertFrom-Json
        Assert-True ([bool]$backup2.hadEnabled -eq $true -and [int]$backup2.enabledValue -eq 1) 'paseo-built-in-backup-not-overwritten-with-zero'

        New-Item -Path $tempOtherRegistryPath -Force | Out-Null
        New-ItemProperty -LiteralPath $tempOtherRegistryPath -Name 'Enabled' -PropertyType DWord -Value 1 -Force | Out-Null
        $wrongKeyRestore = Invoke-NotifyPaseoBuiltInHelper -Action Restore -RegistryPath $tempOtherRegistryPath -StatePath $tempStatePath
        Assert-True (-not $wrongKeyRestore.Ok) 'paseo-built-in-restore-wrong-key-fails'
        $wrongKeyAfter = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempOtherRegistryPath
        Assert-True ($wrongKeyAfter.HadEnabled -and [int]$wrongKeyAfter.EnabledValue -eq 1) 'paseo-built-in-restore-wrong-key-unchanged'

        $restore1 = Invoke-NotifyPaseoBuiltInHelper -Action Restore -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True $restore1.Ok 'paseo-built-in-restore-ok'
        $afterRestore = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempRegistryPath
        Assert-True ($afterRestore.HadEnabled -and [int]$afterRestore.EnabledValue -eq 1) 'paseo-built-in-restore-original-value'
        Assert-True (-not (Test-Path -LiteralPath $tempStatePath)) 'paseo-built-in-backup-deleted-after-restore'

        # Original property absent: Disable creates Enabled=0; Restore removes Enabled.
        Remove-ItemProperty -LiteralPath $tempRegistryPath -Name 'Enabled' -ErrorAction SilentlyContinue
        $absentBefore = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempRegistryPath
        Assert-True (-not $absentBefore.HadEnabled) 'paseo-built-in-absent-before'
        $disableAbsent = Invoke-NotifyPaseoBuiltInHelper -Action Disable -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True $disableAbsent.Ok 'paseo-built-in-disable-absent-ok'
        $backupAbsent = Get-Content -Raw -LiteralPath $tempStatePath | ConvertFrom-Json
        Assert-True ([bool]$backupAbsent.hadEnabled -eq $false) 'paseo-built-in-backup-absent-flag'
        $restoreAbsent = Invoke-NotifyPaseoBuiltInHelper -Action Restore -RegistryPath $tempRegistryPath -StatePath $tempStatePath
        Assert-True $restoreAbsent.Ok 'paseo-built-in-restore-absent-ok'
        $afterAbsent = Get-NotifyPaseoBuiltInEnabledSnapshot -RegistryPath $tempRegistryPath
        Assert-True (-not $afterAbsent.HadEnabled) 'paseo-built-in-restore-removes-enabled'
        Assert-True (-not (Test-Path -LiteralPath $tempStatePath)) 'paseo-built-in-absent-backup-deleted'
    }
    finally {
        try {
            foreach ($path in @($tempRegistryPath, $tempOtherRegistryPath)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $parent = 'HKCU:\Software\PiNotifyTests'
            if (Test-Path -LiteralPath $parent) {
                $remaining = @(Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
Write-Host "`n== Activation coordinator and Terminal pure contracts =="
$activationCommands = @(
    'Select-NotifyTerminalCandidates',
    'Test-NotifyTerminalActivationProof',
    'Normalize-NotifyActivationOriginKind',
    'Test-NotifyActivationStrategyResult',
    'Resolve-NotifyActivationWorkerOutput',
    'Get-NotifyActivationRemainingMs'
)
$activationModulesReady = $true
foreach ($commandName in $activationCommands) {
    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        $activationModulesReady = $false
    }
}

if (-not $activationModulesReady) {
    Write-Host 'SKIP  activation-module-pure-contracts (requires Windows UIAutomation assemblies)'
}
else {
    $canonicalTitle = ([char]0x03c0) + ' - work ' + ([char]0x00b7) + ' #aaaaaaaaaaaa'
    $otherTitle = ([char]0x03c0) + ' - work ' + ([char]0x00b7) + ' #bbbbbbbbbbbb'
    $uniqueWindows = @([pscustomobject]@{
        Handle = [IntPtr]11
        Title = 'Windows Terminal - work'
        ProcessId = 101
        ProcessName = 'WindowsTerminal'
        Tabs = @(
            [pscustomobject]@{ Name = ('decorated ' + $canonicalTitle); Index = 0; IsSelected = $true; Element = $null },
            [pscustomobject]@{ Name = $otherTitle; Index = 1; IsSelected = $false; Element = $null }
        )
    })
    $unique = Select-NotifyTerminalCandidates -TabTitle $canonicalTitle -CwdBase 'work' -Windows $uniqueWindows
    Assert-Equal 'unique' $unique.Result 'terminal-direct-full-title-containment-unique'
    Assert-Equal ('decorated ' + $canonicalTitle) $unique.Selected.TabName 'terminal-direct-full-title-preserved'

    $duplicateWindows = @([pscustomobject]@{
        Handle = [IntPtr]11
        Title = 'Windows Terminal - work'
        ProcessId = 101
        ProcessName = 'WindowsTerminal'
        Tabs = @(
            [pscustomobject]@{ Name = $canonicalTitle; Index = 0; IsSelected = $true; Element = $null },
            [pscustomobject]@{ Name = ('prefix ' + $canonicalTitle); Index = 1; IsSelected = $false; Element = $null }
        )
    })
    $ambiguous = Select-NotifyTerminalCandidates -TabTitle $canonicalTitle -CwdBase 'work' -Windows $duplicateWindows -CachedCandidate ([pscustomobject]@{ WindowHandle = [IntPtr]11; TabName = $canonicalTitle })
    Assert-Equal 'ambiguous' $ambiguous.Result 'terminal-direct-cache-cannot-hide-containing-duplicate'

    $wrongHash = Select-NotifyTerminalCandidates -TabTitle $canonicalTitle -CwdBase 'work' -Windows @([pscustomobject]@{
        Handle = [IntPtr]11; Title = 'Windows Terminal - work'; ProcessId = 101; ProcessName = 'WindowsTerminal'
        Tabs = @([pscustomobject]@{ Name = $otherTitle; Index = 0; IsSelected = $true; Element = $null })
    })
    Assert-Equal 'target-missing' $wrongHash.Result 'terminal-direct-title-blocks-cwd-fallback'

    $cwdLegacy = Select-NotifyTerminalCandidates -CwdBase 'legacy-work' -Windows @([pscustomobject]@{
        Handle = [IntPtr]12; Title = 'Windows Terminal'; ProcessId = 102; ProcessName = 'WindowsTerminal'
        Tabs = @([pscustomobject]@{ Name = 'legacy-work shell'; Index = 0; IsSelected = $true; Element = $null })
    })
    Assert-Equal 'unique' $cwdLegacy.Result 'terminal-direct-cwd-only-legacy'

    $proofOk = Test-NotifyTerminalActivationProof -TabTitle $canonicalTitle -CwdBase 'work' -TargetHandle ([IntPtr]11) -ForegroundHandle ([IntPtr]11) -SelectedTabs @([pscustomobject]@{ Name = ('decorated ' + $canonicalTitle); WindowTitle = 'current work title' })
    Assert-True $proofOk.Ok 'terminal-direct-foreground-selected-proof'
    $proofWrongForeground = Test-NotifyTerminalActivationProof -TabTitle $canonicalTitle -TargetHandle ([IntPtr]11) -ForegroundHandle ([IntPtr]12) -SelectedTabs @([pscustomobject]@{ Name = $canonicalTitle; WindowTitle = '' })
    Assert-Equal 'foreground-proof-failed' $proofWrongForeground.Result 'terminal-direct-foreground-mismatch'
    $proofWrongTitle = Test-NotifyTerminalActivationProof -TabTitle $canonicalTitle -TargetHandle ([IntPtr]11) -ForegroundHandle ([IntPtr]11) -SelectedTabs @([pscustomobject]@{ Name = $otherTitle; WindowTitle = '' })
    Assert-Equal 'selected-tab-proof-failed' $proofWrongTitle.Result 'terminal-direct-selected-title-mismatch'
    $proofLegacyFreshTitle = Test-NotifyTerminalActivationProof -CwdBase 'legacy-work' -TargetHandle ([IntPtr]11) -ForegroundHandle ([IntPtr]11) -SelectedTabs @([pscustomobject]@{ Name = 'shell'; WindowTitle = 'legacy-work current title' })
    Assert-True $proofLegacyFreshTitle.Ok 'terminal-direct-cwd-proof-uses-current-window-title'

    $scrolledRouteResult = New-NotifyTerminalRouteResult -Result 'activated' -ScrollAttempted:$true -ScrolledToBottom:$true
    Assert-True $scrolledRouteResult.ScrollAttempted 'terminal-direct-scroll-attempt-propagated'
    Assert-True $scrolledRouteResult.ScrolledToBottom 'terminal-direct-scroll-result-propagated'
    $unattemptedScrollResult = New-NotifyTerminalRouteResult -Result 'target-missing' -ScrolledToBottom:$true
    Assert-True (-not $unattemptedScrollResult.ScrolledToBottom) 'terminal-direct-scroll-success-requires-attempt'

    Assert-Equal 'terminal' (Normalize-NotifyActivationOriginKind -OriginKind '').OriginKind 'activation-direct-blank-origin-terminal'
    Assert-True (-not (Normalize-NotifyActivationOriginKind -OriginKind 'pi-web-desktop').Ok) 'activation-direct-unknown-origin-fail-closed'

    $missingRequest = Invoke-NotifyActivationStrategy -Request $null
    Assert-Equal 'missing-request' $missingRequest.Reason 'activation-direct-missing-request-fail-closed'
    $unknownRequest = New-NotifyActivationRequest -Operation 'activate' -OriginKind 'pi-web-desktop' -CwdBase 'work' -TabTitle $canonicalTitle
    $unknownOutcome = Invoke-NotifyActivationStrategy -Request $unknownRequest
    Assert-Equal 'unsupported-origin' $unknownOutcome.Result 'activation-direct-explicit-unknown-no-terminal-fallback'
    Assert-True (Test-NotifyActivationStrategyResult -Result $unknownOutcome -ExpectedOperation 'activate') 'activation-direct-unknown-outcome-contract-valid'
    $unknownUi = ConvertTo-NotifyActivationUiOutcome -Outcome $unknownOutcome
    Assert-Equal 'show-unavailable' $unknownUi.Action 'activation-direct-unknown-ui-fail-closed'
    Assert-Equal 'unsupported-origin' $unknownUi.Result 'activation-direct-unknown-ui-classification-preserved'
    $unknownWorker = Resolve-NotifyActivationWorkerOutput -Rows @($unknownOutcome) -Operation 'activate' -OriginKind 'pi-web-desktop'
    Assert-Equal 'unsupported-origin' $unknownWorker.Result 'activation-direct-unknown-worker-classification-preserved'
    $terminalResolve = New-NotifyActivationRequest -Operation 'resolve' -OriginKind 'terminal' -CwdBase 'work'
    Assert-Equal 'resolve-requires-pi-web' (Invoke-NotifyActivationStrategy -Request $terminalResolve).Reason 'activation-direct-resolve-terminal-invalid'
    $paseoWithoutHandle = New-NotifyActivationRequest -Operation 'activate' -OriginKind 'paseo' -CwdBase 'work' -TabTitle $canonicalTitle
    Assert-Equal 'activation-missing' (Invoke-NotifyActivationStrategy -Request $paseoWithoutHandle).Result 'activation-direct-paseo-metadata-no-terminal-repair'
    $piWebWithoutNotification = New-NotifyActivationRequest -Operation 'activate' -OriginKind 'pi-web' -SnapshotId 'snapshot' -CwdBase 'work'
    Assert-Equal 'missing-notification-id' (Invoke-NotifyActivationStrategy -Request $piWebWithoutNotification).Reason 'activation-direct-pi-web-no-terminal-repair'

    $handledOutcome = New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'terminal' -Decision 'handled' -Result 'activated' -ProofState 'final' -ScrollAttempted:$true -ScrolledToBottom:$true
    Assert-True (Test-NotifyActivationStrategyResult -Result $handledOutcome -ExpectedOperation 'activate' -ExpectedOriginKind 'terminal') 'activation-direct-complete-handled-valid'
    Assert-True $handledOutcome.ScrolledToBottom 'activation-direct-scroll-result-preserved'
    $focusedWrongOrigin = New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'terminal' -Decision 'focused' -Result 'pending' -ProofState 'pending' -SnapshotId 'snapshot'
    Assert-True (-not (Test-NotifyActivationStrategyResult -Result $focusedWrongOrigin)) 'activation-direct-focused-terminal-invalid'
    $readyWrongOperation = New-NotifyActivationOutcome -Operation 'activate' -OriginKind 'pi-web' -Decision 'ready' -Result 'ready' -SnapshotId 'snapshot'
    Assert-True (-not (Test-NotifyActivationStrategyResult -Result $readyWrongOperation)) 'activation-direct-ready-activate-invalid'

    $emptyWorker = Resolve-NotifyActivationWorkerOutput -Rows @() -Operation 'activate' -OriginKind 'terminal'
    Assert-Equal 'worker-empty' $emptyWorker.Reason 'activation-direct-worker-empty-complete'
    Assert-True (Test-NotifyActivationStrategyResult -Result $emptyWorker) 'activation-direct-worker-empty-shape-valid'
    $multipleWorker = Resolve-NotifyActivationWorkerOutput -Rows @($handledOutcome, $handledOutcome) -Operation 'activate' -OriginKind 'terminal'
    Assert-Equal 'worker-output-count' $multipleWorker.Reason 'activation-direct-worker-multiple-fail-closed'
    $malformedWorker = Resolve-NotifyActivationWorkerOutput -Rows @([pscustomobject]@{ Decision = 'handled' }) -Operation 'activate' -OriginKind 'terminal'
    Assert-Equal 'worker-malformed' $malformedWorker.Reason 'activation-direct-worker-malformed-fail-closed'

    $deadline = [DateTime]::new(2030, 1, 1, 0, 0, 10, [DateTimeKind]::Utc)
    $before = [DateTime]::new(2030, 1, 1, 0, 0, 7, [DateTimeKind]::Utc)
    $after = [DateTime]::new(2030, 1, 1, 0, 0, 11, [DateTimeKind]::Utc)
    Assert-Equal 3000 (Get-NotifyActivationRemainingMs -ExpiresAtUtc $deadline -NowUtc $before) 'activation-direct-immutable-expiry-before'
    Assert-Equal 0 (Get-NotifyActivationRemainingMs -ExpiresAtUtc $deadline -NowUtc $after) 'activation-direct-immutable-expiry-after'
}

# Summary
Write-Host ""
Write-Host ("Results: {0} passed, {1} failed" -f $script:TestPasses, $script:TestFailures)
if ($script:TestFailures -gt 0) {
    exit 1
}
exit 0
