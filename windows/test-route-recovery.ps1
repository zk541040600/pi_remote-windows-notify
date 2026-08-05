[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1')

$script:RecoveryTestTicket = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$script:RecoveryTestSnapshot = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$script:RecoveryTestResolveCalls = 0
$script:RecoveryTestRequests = New-Object System.Collections.ArrayList

$script:NotifyRouteHostClientMock = {
    param($request, $waitMs)

    [void]$script:RecoveryTestRequests.Add($request)
    foreach ($forbidden in @('sessionId', 'rawSessionId', 'url', 'token')) {
        if ($request.ContainsKey($forbidden)) {
            throw "unsafe route field crossed client boundary: $forbidden"
        }
    }

    switch ([string]$request.type) {
        'freeze' {
            if ([int]$request.recoveryTtlMs -ne 120000) {
                throw 'freeze did not opt into the bounded recovery ticket'
            }
            return [pscustomobject]@{
                Available = $true
                Result = 'recovering'
                Reason = 'owner-unresolved'
                SnapshotId = ''
                RecoveryTicketId = $script:RecoveryTestTicket
            }
        }
        'resolve-recovery' {
            $script:RecoveryTestResolveCalls += 1
            if ([string]$request.recoveryTicketId -ne $script:RecoveryTestTicket) {
                throw 'resolve changed the opaque recovery ticket'
            }
            if ($script:RecoveryTestResolveCalls -eq 1) {
                return [pscustomobject]@{
                    Available = $true
                    Result = 'recovering'
                    Reason = 'owner-unresolved'
                    SnapshotId = ''
                    RecoveryTicketId = $script:RecoveryTestTicket
                }
            }
            return [pscustomobject]@{
                Available = $true
                Result = 'ready'
                Reason = ''
                SnapshotId = $script:RecoveryTestSnapshot
                RecoveryTicketId = $script:RecoveryTestTicket
            }
        }
        'activate' {
            if ([string]$request.snapshotId -ne $script:RecoveryTestSnapshot) {
                throw 'activate did not use the resolved immutable snapshot'
            }
            return [pscustomobject]@{
                Available = $true
                Result = 'session-url-confirmed'
                Reason = ''
                SnapshotId = $script:RecoveryTestSnapshot
                RecoveryTicketId = ''
                ActivationRequestId = [string]$request.requestId
            }
        }
        default { throw "unexpected request type: $($request.type)" }
    }
}

$notificationId = '11111111-1111-4111-8111-111111111111'
$freeze = Invoke-NotifyExactRouteFreeze `
    -NotificationId $notificationId `
    -NotificationKind 'turn-complete' `
    -InstanceKey '22222222-2222-4222-8222-222222222222' `
    -RoutingKey ('c' * 64)
if ($freeze.Decision -ne 'exact-recovering' -or
    $freeze.RecoveryTicketId -ne $script:RecoveryTestTicket) {
    throw 'freeze did not return the recovery ticket'
}

$activation = Invoke-NotifyExactRouteRecoveryAndActivate `
    -NotificationId $notificationId `
    -RecoveryTicketId $script:RecoveryTestTicket `
    -RecoveryWaitMs 2000 `
    -ActivateWaitMs 15000 `
    -ActivateTimeoutMs 18000
if ($activation.Decision.Decision -ne 'handled') {
    throw "recovered activation was not handled: $($activation.Decision.Decision)"
}
if ($activation.SnapshotId -ne $script:RecoveryTestSnapshot) {
    throw 'recovered activation returned the wrong snapshot'
}
if ($script:RecoveryTestResolveCalls -ne 2) {
    throw "unexpected recovery poll count: $script:RecoveryTestResolveCalls"
}

$mismatch = Get-NotifyRouteRecoveryDecision `
    -ClientResult ([pscustomobject]@{
        Available = $true
        Result = 'ready'
        Reason = ''
        SnapshotId = $script:RecoveryTestSnapshot
        RecoveryTicketId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    }) `
    -NotificationId $notificationId `
    -RecoveryTicketId $script:RecoveryTestTicket
if ($mismatch.Decision -ne 'fail-closed') {
    throw 'a mismatched recovery ticket did not fail closed'
}

Write-Output ('PASS route-recovery requests={0}' -f $script:RecoveryTestRequests.Count)
