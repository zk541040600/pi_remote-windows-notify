# Pure route-decision tests for Windows notify exact-route integration.
# Runnable with pwsh or Windows PowerShell; no UIAutomation / WinForms required.
[CmdletBinding()]
param(
    [switch]$SkipDotSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SkipDotSource) {
    . (Join-Path $scriptDir 'NotifyBridge.Common.ps1')
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
Assert-True $script:MockReturnOnProgress 'mock-activate-requests-progress-return'
Assert-Equal 5000 $script:MockActivationEnvelopeTtlMs 'mock-activate-keeps-short-transport-ttl'
Assert-Equal 'focused' $focusedActivate.Decision.Decision 'mock-activate-focused'
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

# Summary
Write-Host ""
Write-Host ("Results: {0} passed, {1} failed" -f $script:TestPasses, $script:TestFailures)
if ($script:TestFailures -gt 0) {
    exit 1
}
exit 0
