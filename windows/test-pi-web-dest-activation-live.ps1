param(
    [switch]$ConfirmLive,
    [string]$DesktopExe = '',
    [int]$ActivationTimeoutSeconds = 55,
    [int]$PopupReadyTimeoutSeconds = 8,
    [int]$SampleIntervalMilliseconds = 50,
    [string]$StatusPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Live, user-state-preserving Dest App regression test.
#
# The default invocation is a dry run. -ConfirmLive creates broker-only test
# popups and activates them automatically, but it never starts, stops, or
# restarts PiWebDesktop and never deletes WebView/session data. The initially
# selected session is restored in finally through the same exact-route path.

$script:FailureCode = ''
$script:FailureKinds = [System.Collections.Generic.List[string]]::new()
$script:StatusFile = ''
$script:StartedAtUtc = [DateTime]::UtcNow
$script:RouteLog = ''
$script:BrokerLog = ''
$script:BrokerPort = 0
$script:DesktopPath = ''
$script:DesktopPid = 0
$script:DesktopHwnd = [long]0
$script:DesktopRunId = ''
$script:OriginalTarget = $null
$script:OriginalBindingInvariant = $null
$script:OriginalBindingSurfaceInvariant = $null
$script:Restored = $false
$script:PopupIds = [System.Collections.Generic.List[string]]::new()
$script:NotificationFingerprints = [System.Collections.Generic.List[string]]::new()
$script:ActivationResults = [System.Collections.Generic.List[object]]::new()
$script:RecoveryTimingResult = $null
$script:IdentitySamples = 0
$script:IdentityViolation = ''
$script:NotifyConfig = $null
$script:NotifyRuntimeConfig = $null
$script:RouteConfig = $null
$script:PreferencesPath = ''

function Write-SafeEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][hashtable]$Fields
    )

    $record = [ordered]@{
        type  = 'pi-web-dest-activation-live'
        phase = $Phase
    }
    foreach ($entry in $Fields.GetEnumerator()) {
        $record[$entry.Key] = $entry.Value
    }
    $line = $record | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    if (-not [string]::IsNullOrWhiteSpace($script:StatusFile)) {
        [System.IO.File]::AppendAllText(
            $script:StatusFile,
            $line + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false))
    }
}

function Add-FailureKind {
    param([Parameter(Mandatory = $true)][string]$Code)

    if (-not $script:FailureKinds.Contains($Code)) {
        [void]$script:FailureKinds.Add($Code)
    }
    if ([string]::IsNullOrWhiteSpace($script:FailureCode)) {
        $script:FailureCode = $Code
    }
}

function Stop-LiveTest {
    param([Parameter(Mandatory = $true)][string]$Code)

    Add-FailureKind -Code $Code
    throw [System.InvalidOperationException]::new('DEST_LIVE_ABORT')
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Value)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-SafeFingerprint {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (Get-Sha256Hex -Value $Value).Substring(0, 16)
}

function Get-PiWebRoutingKey {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceKey,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    return Get-Sha256Hex -Value (
        'pi-web-route-v1' + [char]0 + $InstanceKey + [char]0 + $SessionId)
}

function Get-RouteBindingId {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceKey,
        [Parameter(Mandatory = $true)][string]$RoutingKey
    )

    return Get-Sha256Hex -Value ($InstanceKey + [char]0 + $RoutingKey)
}

function Read-JsonObjectSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FailureCode
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Stop-LiveTest -Code $FailureCode
        }
        $value = [System.IO.File]::ReadAllText($Path) |
            ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value) { Stop-LiveTest -Code $FailureCode }
        return $value
    }
    catch {
        if ($_.Exception.Message -eq 'DEST_LIVE_ABORT') { throw }
        Stop-LiveTest -Code $FailureCode
    }
}

function Get-RouteEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Tail = 6000
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $events = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($line in (Get-Content -LiteralPath $Path -Tail $Tail)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                if ($record.PSObject.Properties['eventName'] -and
                    $record.PSObject.Properties['timestamp'] -and
                    $record.PSObject.Properties['processId']) {
                    [void]$events.Add($record)
                }
            }
            catch {
                # A writer may have an incomplete final line. Retry next poll.
            }
        }
    }
    catch {
        return @()
    }
    return $events.ToArray()
}

function ConvertTo-EventUtc {
    param($EventRecord)

    try {
        return [DateTimeOffset]::Parse(
            [string]$EventRecord.timestamp,
            [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Get-EventDocumentGeneration {
    param($EventRecord)

    if ($null -eq $EventRecord -or $null -eq $EventRecord.fields) {
        return [long]::MinValue
    }
    $property = $EventRecord.fields.PSObject.Properties['documentGeneration']
    if ($null -eq $property) { return [long]::MinValue }
    try { return [long]$property.Value } catch { return [long]::MinValue }
}

function Get-BrokerLines {
    param([int]$Tail = 6000)

    if ([string]::IsNullOrWhiteSpace($script:BrokerLog) -or
        -not (Test-Path -LiteralPath $script:BrokerLog -PathType Leaf)) {
        return @()
    }
    # Windows PowerShell decorates strings emitted by Get-Content with file
    # provider properties (PSPath, PSDrive, PSProvider, ...).  Passing those
    # decorated strings to ConvertTo-Json -Depth 12 during final evidence
    # emission can recursively expand the provider graph and consume a CPU
    # indefinitely.  A direct [string] copy strips that hidden ETS metadata.
    try {
        return @(Get-Content -LiteralPath $script:BrokerLog -Tail $Tail |
            ForEach-Object { [string]$_ })
    }
    catch { return @() }
}

function ConvertTo-BrokerLineUtc {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return [DateTime]::MinValue }
    $match = [regex]::Match($Line, '^\[(?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]')
    if (-not $match.Success) { return [DateTime]::MinValue }
    try {
        $local = [DateTime]::ParseExact(
            $match.Groups['stamp'].Value,
            'yyyy-MM-dd HH:mm:ss.fff',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal)
        return $local.ToUniversalTime()
    }
    catch { return [DateTime]::MinValue }
}

function Get-DesktopProcesses {
    param([string]$ExactPath = '')

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'PiWebDesktop' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $currentSessionId) { continue }
            $path = [string]$process.Path
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if (-not [string]::IsNullOrWhiteSpace($ExactPath) -and
                -not [string]::Equals(
                    [System.IO.Path]::GetFullPath($path),
                    [System.IO.Path]::GetFullPath($ExactPath),
                    [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            [void]$items.Add($process)
        }
        catch {
            # Process may exit during enumeration.
        }
    }
    return $items.ToArray()
}

function Resolve-DesktopExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        try {
            $resolved = (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
            if ([System.IO.Path]::GetExtension($resolved) -ne '.exe') {
                Stop-LiveTest -Code 'DESKTOP_EXE_INVALID'
            }
            return [System.IO.Path]::GetFullPath($resolved)
        }
        catch {
            if ($_.Exception.Message -eq 'DEST_LIVE_ABORT') { throw }
            Stop-LiveTest -Code 'DESKTOP_EXE_INVALID'
        }
    }

    $paths = @(Get-DesktopProcesses | ForEach-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.Path) } catch { $null }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    if ($paths.Count -ne 1) { Stop-LiveTest -Code 'DESKTOP_EXE_REQUIRED' }
    return $paths[0]
}

if (-not ('DestAppE2EWindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DestAppE2EWindowProbe
{
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    public static IntPtr[] GetVisibleRootWindows(int processId)
    {
        var result = new List<IntPtr>();
        EnumWindows((hwnd, state) =>
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(hwnd, out ownerProcessId);
            if (ownerProcessId == (uint)processId &&
                IsWindowVisible(hwnd) &&
                GetWindow(hwnd, 4) == IntPtr.Zero)
            {
                result.Add(hwnd);
            }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@
}

function Get-DesktopIdentitySample {
    $script:IdentitySamples += 1
    $all = @(Get-DesktopProcesses)
    $matching = @(Get-DesktopProcesses -ExactPath $script:DesktopPath)
    $result = [ordered]@{
        ok          = $false
        code        = ''
        processCount = $all.Count
        exactCount  = $matching.Count
        pid         = 0
        hwnd        = '0x0'
        rootWindows = @()
    }
    if ($all.Count -ne 1 -or $matching.Count -ne 1) {
        $result.code = 'DESKTOP_PROCESS_COUNT_CHANGED'
        return [pscustomobject]$result
    }

    $process = $matching[0]
    try { $process.Refresh() } catch {}
    $mainHwnd = [long]$process.MainWindowHandle
    $windows = @([DestAppE2EWindowProbe]::GetVisibleRootWindows([int]$process.Id) |
        ForEach-Object { [long]$_ } | Sort-Object)
    $result.pid = [int]$process.Id
    $result.hwnd = ('0x{0:X}' -f $mainHwnd)
    $result.rootWindows = @($windows | ForEach-Object { '0x{0:X}' -f $_ })

    if ([int]$process.Id -ne $script:DesktopPid) {
        $result.code = 'DESKTOP_PID_CHANGED'
        return [pscustomobject]$result
    }
    if ($mainHwnd -ne $script:DesktopHwnd -or $script:DesktopHwnd -eq 0) {
        $result.code = 'DESKTOP_MAIN_HWND_CHANGED'
        return [pscustomobject]$result
    }
    if ($windows.Count -ne 1 -or $windows[0] -ne $script:DesktopHwnd) {
        $result.code = 'DESKTOP_ROOT_WINDOW_CHANGED'
        return [pscustomobject]$result
    }
    $result.ok = $true
    return [pscustomobject]$result
}

function Record-DesktopIdentitySample {
    $sample = Get-DesktopIdentitySample
    if (-not $sample.ok -and [string]::IsNullOrWhiteSpace($script:IdentityViolation)) {
        $script:IdentityViolation = [string]$sample.code
    }
    return $sample
}

function Get-LatestStableRouteState {
    param([int]$WaitSeconds = 0)

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSeconds))
    do {
        $events = @(Get-RouteEvents -Path $script:RouteLog -Tail 6000 |
            Where-Object {
                [int]$_.processId -eq $script:DesktopPid -and
                [string]$_.runId -eq $script:DesktopRunId
            } | Sort-Object { ConvertTo-EventUtc -EventRecord $_ })
        $generationEvents = @($events | Where-Object {
            (Get-EventDocumentGeneration -EventRecord $_) -ne [long]::MinValue
        })
        $currentGeneration = if ($generationEvents.Count -gt 0) {
            Get-EventDocumentGeneration -EventRecord $generationEvents[-1]
        } else {
            [long]::MinValue
        }
        $proofs = @($events | Where-Object {
            [string]$_.eventName -eq 'route-session-proof' -and
            $_.fields -and
            $_.fields.PSObject.Properties['accepted'] -and
            [bool]$_.fields.accepted -and
            $_.fields.PSObject.Properties['routingFp'] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.fields.routingFp) -and
            (Get-EventDocumentGeneration -EventRecord $_) -eq $currentGeneration
        })
        if ($proofs.Count -gt 0) {
            $proof = $proofs[-1]
            $proofUtc = ConvertTo-EventUtc -EventRecord $proof
            $laterDifferentHistory = @($events | Where-Object {
                [string]$_.eventName -eq 'route-history-changed' -and
                (ConvertTo-EventUtc -EventRecord $_) -gt $proofUtc -and
                $_.fields.PSObject.Properties['routingFp'] -and
                [string]$_.fields.routingFp -ne [string]$proof.fields.routingFp
            })
            if ($laterDifferentHistory.Count -eq 0) {
                return [pscustomobject]@{
                    RoutingFingerprint = [string]$proof.fields.routingFp
                    DocumentGeneration = Get-EventDocumentGeneration -EventRecord $proof
                    TimestampUtc       = $proofUtc
                }
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    } while ($true)
    return $null
}

function Get-BindingEntry {
    param(
        [Parameter(Mandatory = $true)]$Preferences,
        [Parameter(Mandatory = $true)][string]$BindingId,
        [Parameter(Mandatory = $true)]$RouteConfig
    )

    if (-not $Preferences.PSObject.Properties['sessions'] -or
        $null -eq $Preferences.sessions) { return $null }
    $property = $Preferences.sessions.PSObject.Properties[$BindingId]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $binding = $property.Value
    if (-not $binding.PSObject.Properties['adapterIdentity'] -or
        $null -eq $binding.adapterIdentity) { return $null }
    $identity = $binding.adapterIdentity
    if ([string]$identity.adapterKind -ne 'pi-web-desktop' -or
        [string]$identity.profileKey -ne [string]$RouteConfig.ProfileKey -or
        [string]$binding.adapterKey -ne [string]$RouteConfig.AdapterKey) {
        return $null
    }
    return $binding
}

function Get-BindingInvariant {
    param($Binding)

    if ($null -eq $Binding) { return $null }
    return [pscustomobject]@{
        adapterKey       = [string]$Binding.adapterKey
        openEventId      = [string]$Binding.openEventId
        openedAtMs       = [string]$Binding.openedAtMs
        revision         = [string]$Binding.revision
        receiveClockEpoch = [string]$Binding.receiveClockEpoch
        ownerKind        = [string]$Binding.adapterIdentity.adapterKind
        browserKind      = [string]$Binding.adapterIdentity.browserKind
        profileKey       = [string]$Binding.adapterIdentity.profileKey
    }
}

function Test-BindingInvariantEqual {
    param($Expected, $Actual)

    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    return [string]$Expected.adapterKey -eq [string]$Actual.adapterKey -and
        [string]$Expected.openEventId -eq [string]$Actual.openEventId -and
        [string]$Expected.openedAtMs -eq [string]$Actual.openedAtMs -and
        [string]$Expected.revision -eq [string]$Actual.revision -and
        [string]$Expected.receiveClockEpoch -eq
            [string]$Actual.receiveClockEpoch -and
        [string]$Expected.ownerKind -eq [string]$Actual.ownerKind -and
        [string]$Expected.browserKind -eq [string]$Actual.browserKind -and
        [string]$Expected.profileKey -eq [string]$Actual.profileKey
}

function Read-TargetBindingInvariant {
    param([Parameter(Mandatory = $true)]$Target)

    $preferences = Read-JsonObjectSafe `
        -Path $script:PreferencesPath `
        -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'
    $binding = Get-BindingEntry `
        -Preferences $preferences `
        -BindingId ([string]$Target.BindingId) `
        -RouteConfig $script:RouteConfig
    return Get-BindingInvariant -Binding $binding
}

function Invoke-BrokerRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Payload = $null
    )

    try {
        $parameters = @{
            UseBasicParsing = $true
            Method          = $Method
            Uri             = ('http://127.0.0.1:{0}{1}' -f $script:BrokerPort, $Path)
            TimeoutSec      = 3
        }
        if ($Method -eq 'POST') {
            $parameters['ContentType'] = 'application/json; charset=utf-8'
            $parameters['Body'] = $Payload | ConvertTo-Json -Depth 6 -Compress
        }
        $response = Invoke-WebRequest @parameters
        return [int]$response.StatusCode -eq 200
    }
    catch { return $false }
}

function Wait-BrokerPopup {
    param(
        [Parameter(Mandatory = $true)][string]$NotificationFingerprint,
        [Parameter(Mandatory = $true)][DateTime]$NotBeforeUtc
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($PopupReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $lines = @(Get-BrokerLines | Where-Object {
            $_ -match 'broker-popup-queue-dequeue\b' -and
            $_ -match ('notificationFp=' + [regex]::Escape($NotificationFingerprint) + '\b') -and
            (ConvertTo-BrokerLineUtc -Line $_) -ge $NotBeforeUtc.AddSeconds(-1)
        })
        if ($lines.Count -gt 0) {
            $queueLine = $lines[-1]
            $queueUtc = ConvertTo-BrokerLineUtc -Line $queueLine
            $match = [regex]::Match(
                $queueLine,
                '\bpopupId=(?<popupId>[A-Za-z0-9._-]{1,64})\b')
            if ($match.Success) {
                $popupId = $match.Groups['popupId'].Value
                $shown = @(Get-BrokerLines | Where-Object {
                    $_ -match ('\bbroker-shown\s+popupId=' +
                        [regex]::Escape($popupId) + '\b') -and
                    (ConvertTo-BrokerLineUtc -Line $_) -ge $queueUtc -and
                    (ConvertTo-BrokerLineUtc -Line $_) -ge $NotBeforeUtc.AddSeconds(-1)
                })
                if ($shown.Count -gt 0) { return $popupId }
            }
        }
        Start-Sleep -Milliseconds 20
    }
    return ''
}

function Update-TestPopupIdsFromBroker {
    if ($script:NotificationFingerprints.Count -eq 0) { return }
    $lines = @(Get-BrokerLines | Where-Object {
        $_ -match '^\[[^]]+\]\s+broker-popup-queue-dequeue\b' -and
        (ConvertTo-BrokerLineUtc -Line $_) -ge
            $script:StartedAtUtc.AddSeconds(-2)
    })
    foreach ($notificationFp in $script:NotificationFingerprints) {
        if ([string]::IsNullOrWhiteSpace($notificationFp)) { continue }
        foreach ($line in @($lines | Where-Object {
            $_ -match ('\bnotificationFp=' +
                [regex]::Escape($notificationFp) + '\b')
        })) {
            $match = [regex]::Match(
                $line,
                '\bpopupId=(?<popupId>[A-Za-z0-9._-]{1,64})\b')
            if (-not $match.Success) { continue }
            $popupId = $match.Groups['popupId'].Value
            if (-not $script:PopupIds.Contains($popupId)) {
                [void]$script:PopupIds.Add($popupId)
            }
        }
    }
}

function Close-AllTestPopups {
    param([int]$DiscoveryWaitMilliseconds = 0)

    if ($script:BrokerPort -le 0 -or
        ($script:NotificationFingerprints.Count -eq 0 -and
         $script:PopupIds.Count -eq 0)) {
        return
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds(
        [Math]::Max(0, $DiscoveryWaitMilliseconds))
    do {
        Update-TestPopupIdsFromBroker
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 50
    } while ($true)

    foreach ($popupId in @($script:PopupIds)) {
        if ([string]::IsNullOrWhiteSpace($popupId) -or $script:BrokerPort -le 0) {
            continue
        }
        [void](Invoke-BrokerRequest -Method POST -Path '/close' -Payload @{
            popupId = $popupId
            activate = $false
        })
    }
}

function New-ExactRoutePopup {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][int]$StackIndex,
        [string]$Label = 'activation'
    )

    $notificationId = [Guid]::NewGuid().ToString('D')
    $notificationFp = Get-SafeFingerprint -Value $notificationId
    [void]$script:NotificationFingerprints.Add($notificationFp)
    $freeze = Invoke-NotifyExactRouteFreeze `
        -NotificationId $notificationId `
        -NotificationKind 'turn-complete' `
        -InstanceKey ([string]$script:RouteConfig.InstanceKey) `
        -RoutingKey ([string]$Target.RoutingKey) `
        -Config $script:NotifyRuntimeConfig `
        -TimeoutMs 5000
    if ([string]$freeze.Decision -ne 'exact-ready' -or
        [string]::IsNullOrWhiteSpace([string]$freeze.SnapshotId)) {
        return [pscustomobject]@{
            Ok = $false; Code = 'EXACT_FREEZE_NOT_READY'; PopupId = ''
            NotificationId = $notificationId; NotificationFingerprint = $notificationFp
            SnapshotId = ''; PostedAtUtc = [DateTime]::MinValue
        }
    }

    $postedAt = [DateTime]::UtcNow
    $payload = [ordered]@{
        title             = 'Dest App E2E'
        body              = 'Exact session activation check'
        focusTarget       = 'dest-app-e2e'
        targetFingerprint = Get-Sha256Hex -Value ('dest-app-e2e:' + $notificationId)
        stackIndex        = $StackIndex
        timeoutSeconds    = 60
        popupPlacement    = [string]$script:NotifyConfig.popupPlacement
        originKind        = 'pi-web'
        notificationId    = $notificationId
        snapshotId        = [string]$freeze.SnapshotId
        sessionName       = $Label
    }
    if (-not (Invoke-BrokerRequest -Method POST -Path '/popup' -Payload $payload)) {
        return [pscustomobject]@{
            Ok = $false; Code = 'BROKER_POPUP_POST_FAILED'; PopupId = ''
            NotificationId = $notificationId; NotificationFingerprint = $notificationFp
            SnapshotId = [string]$freeze.SnapshotId; PostedAtUtc = $postedAt
        }
    }
    $popupId = Wait-BrokerPopup `
        -NotificationFingerprint $notificationFp `
        -NotBeforeUtc $postedAt
    if ([string]::IsNullOrWhiteSpace($popupId)) {
        return [pscustomobject]@{
            Ok = $false; Code = 'BROKER_POPUP_NOT_SHOWN'; PopupId = ''
            NotificationId = $notificationId; NotificationFingerprint = $notificationFp
            SnapshotId = [string]$freeze.SnapshotId; PostedAtUtc = $postedAt
        }
    }
    [void]$script:PopupIds.Add($popupId)
    return [pscustomobject]@{
        Ok = $true; Code = ''; PopupId = $popupId
        NotificationId = $notificationId; NotificationFingerprint = $notificationFp
        SnapshotId = [string]$freeze.SnapshotId; PostedAtUtc = $postedAt
    }
}

function Get-BindingSurfaceInvariant {
    $preferences = Read-JsonObjectSafe `
        -Path $script:PreferencesPath `
        -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'
    $rows = [System.Collections.Generic.List[string]]::new()
    if ($preferences.PSObject.Properties['sessions'] -and
        $null -ne $preferences.sessions) {
        foreach ($property in @($preferences.sessions.PSObject.Properties |
            Sort-Object Name)) {
            $binding = $property.Value
            if ($null -eq $binding) { continue }
            $identity = if ($binding.PSObject.Properties['adapterIdentity'] -and
                $null -ne $binding.adapterIdentity) {
                $binding.adapterIdentity
            } else {
                $null
            }
            $identityAdapterKind = if ($null -eq $identity) {
                ''
            } else { [string]$identity.adapterKind }
            $identityBrowserKind = if ($null -eq $identity) {
                ''
            } else { [string]$identity.browserKind }
            $identityProfileKey = if ($null -eq $identity) {
                ''
            } else { [string]$identity.profileKey }
            [void]$rows.Add([string]::Join('|', @(
                [string]$property.Name,
                [string]$binding.adapterKey,
                [string]$binding.openEventId,
                [string]$binding.openedAtMs,
                [string]$binding.revision,
                [string]$binding.receiveClockEpoch,
                $identityAdapterKind,
                $identityBrowserKind,
                $identityProfileKey)))
        }
    }
    $joined = [string]::Join("`n", $rows.ToArray())
    return [pscustomobject]@{
        Count       = $rows.Count
        Fingerprint = Get-SafeFingerprint -Value $joined
    }
}

function Test-EventField {
    param(
        $EventRecord,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Expected
    )

    if ($null -eq $EventRecord -or $null -eq $EventRecord.fields) { return $false }
    $property = $EventRecord.fields.PSObject.Properties[$Name]
    if ($null -eq $property) { return $false }
    return [string]$property.Value -eq [string]$Expected
}

function Get-ActivationRouteEvents {
    param([Parameter(Mandatory = $true)][DateTime]$NotBeforeUtc)

    return @(Get-RouteEvents -Path $script:RouteLog -Tail 6000 | Where-Object {
        [int]$_.processId -eq $script:DesktopPid -and
        [string]$_.runId -eq $script:DesktopRunId -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $NotBeforeUtc.AddMilliseconds(-100)
    })
}

function Get-CapturedRowRoutingFingerprints {
    param([Parameter(Mandatory = $true)][long]$DocumentGeneration)

    $events = @(Get-RouteEvents -Path $script:RouteLog -Tail 6000 | Where-Object {
        [int]$_.processId -eq $script:DesktopPid -and
        [string]$_.runId -eq $script:DesktopRunId -and
        (Get-EventDocumentGeneration -EventRecord $_) -eq $DocumentGeneration
    } | Sort-Object { ConvertTo-EventUtc -EventRecord $_ })
    $intents = @($events | Where-Object {
        [string]$_.eventName -eq 'route-intent-accepted' -and
        (Test-EventField $_ 'intentKind' 'sidebar') -and
        $_.fields.PSObject.Properties['routingFp'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.fields.routingFp)
    })
    $proofs = @($events | Where-Object {
        [string]$_.eventName -eq 'route-session-proof' -and
        (Test-EventField $_ 'accepted' $true) -and
        $_.fields.PSObject.Properties['reason'] -and
        [string]$_.fields.reason -in @(
            'api-response-confirmed',
            'api-response-confirmed-source-promoted') -and
        $_.fields.PSObject.Properties['routingFp'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.fields.routingFp)
    })
    $captured = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($intent in $intents) {
        $intentUtc = ConvertTo-EventUtc -EventRecord $intent
        $routingFp = [string]$intent.fields.routingFp
        if (@($proofs | Where-Object {
            (Test-EventField $_ 'routingFp' $routingFp) -and
            (ConvertTo-EventUtc -EventRecord $_) -ge $intentUtc
        }).Count -gt 0) {
            [void]$captured.Add($routingFp)
        }
    }
    return @($captured)
}

function Test-CapturedRowEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$RoutingFingerprint,
        [Parameter(Mandatory = $true)][long]$DocumentGeneration
    )

    return @(Get-CapturedRowRoutingFingerprints `
        -DocumentGeneration $DocumentGeneration) -contains $RoutingFingerprint
}

function Invoke-LiveExactActivation {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$StepName,
        [int]$StackIndex = 0,
        [switch]$RestorationOnly
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $beforeState = Get-LatestStableRouteState -WaitSeconds 3
    if ($null -eq $beforeState) {
        [void]$failures.Add('CURRENT_SESSION_UNSTABLE')
        return [pscustomobject]@{
            Step = $StepName; Ok = $false; Handled = $false
            Failures = $failures.ToArray(); PopupId = ''; NotificationFp = ''
            RoutingFp = [string]$Target.RoutingFingerprint
            BeforeDocumentGeneration = -1; AfterDocumentGeneration = -1
            RowClickReceiptCount = 0; HistoryReceiptCount = 0
            SessionGetProofCount = 0; ExplicitOpenEventCount = 0
            NavigationStartingCount = 0; FreshFallbackCount = 0
            BindingCountBefore = 0; BindingCountAfter = 0
            IdentitySamples = 0; ElapsedMs = 0
            PopupElapsedMs = -1; PopupOutcome = ''
        }
    }
    $beforeGeneration = [long]$beforeState.DocumentGeneration
    if (-not $RestorationOnly -and
        [string]$beforeState.RoutingFingerprint -eq
            [string]$Target.RoutingFingerprint) {
        [void]$failures.Add('TARGET_ALREADY_CURRENT')
    }

    $bindingBefore = Read-TargetBindingInvariant -Target $Target
    $surfaceBefore = Get-BindingSurfaceInvariant
    if ($null -eq $bindingBefore) { [void]$failures.Add('TARGET_BINDING_MISSING_BEFORE') }

    if (-not $RestorationOnly -and
        -not (Test-CapturedRowEvidence `
            -RoutingFingerprint ([string]$Target.RoutingFingerprint) `
            -DocumentGeneration $beforeGeneration)) {
        [void]$failures.Add('TARGET_ROW_WEAKREF_NOT_EVIDENCED')
    }

    $popup = New-ExactRoutePopup `
        -Target $Target `
        -StackIndex $StackIndex `
        -Label $StepName
    if (-not $popup.Ok) {
        [void]$failures.Add([string]$popup.Code)
        return [pscustomobject]@{
            Step = $StepName; Ok = $false; Handled = $false
            Failures = $failures.ToArray(); PopupId = [string]$popup.PopupId
            NotificationFp = [string]$popup.NotificationFingerprint
            RoutingFp = [string]$Target.RoutingFingerprint
            BeforeDocumentGeneration = $beforeGeneration
            AfterDocumentGeneration = $beforeGeneration
            RowClickReceiptCount = 0; HistoryReceiptCount = 0
            SessionGetProofCount = 0; ExplicitOpenEventCount = 0
            NavigationStartingCount = 0; FreshFallbackCount = 0
            BindingCountBefore = 0; BindingCountAfter = 0
            IdentitySamples = 0; ElapsedMs = 0
            PopupElapsedMs = -1; PopupOutcome = ''
        }
    }

    $sampleCountBefore = $script:IdentitySamples
    $clickAtUtc = [DateTime]::UtcNow
    if (-not (Invoke-BrokerRequest -Method POST -Path '/close' -Payload @{
        popupId = [string]$popup.PopupId
        activate = $true
    })) {
        [void]$failures.Add('BROKER_CLICK_FAILED')
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($ActivationTimeoutSeconds)
    $closedObserved = $false
    $adapterCompleteObserved = $false
    do {
        $sample = Record-DesktopIdentitySample
        if (-not $sample.ok -and -not $failures.Contains([string]$sample.code)) {
            [void]$failures.Add([string]$sample.code)
        }

        $brokerLines = @(Get-BrokerLines | Where-Object {
            $_ -match ('\bpopupId=' + [regex]::Escape([string]$popup.PopupId) + '\b')
        })
        $closedObserved = @($brokerLines | Where-Object {
            $_ -match '^\[[^]]+\]\s+broker-closed\b'
        }).Count -gt 0
        $events = Get-ActivationRouteEvents -NotBeforeUtc $clickAtUtc
        $adapterCompleteObserved = @($events | Where-Object {
            [string]$_.eventName -eq 'poll-activate-complete' -and
            (Test-EventField -EventRecord $_ -Name 'notificationFp' `
                -Expected ([string]$popup.NotificationFingerprint))
        }).Count -gt 0
        # A focused popup closes before the exact GET proof by design. Keep the
        # live verifier attached to the independent Desktop terminal chain so
        # early UX completion can never be mistaken for final route success.
        if ($closedObserved -and $adapterCompleteObserved) { break }
        Start-Sleep -Milliseconds $SampleIntervalMilliseconds
    } while ([DateTime]::UtcNow -lt $deadline)

    $finishedAtUtc = [DateTime]::UtcNow
    $elapsedMs = [int]($finishedAtUtc - $clickAtUtc).TotalMilliseconds
    $events = Get-ActivationRouteEvents -NotBeforeUtc $clickAtUtc
    $brokerLines = @(Get-BrokerLines | Where-Object {
        $_ -match ('\bpopupId=' + [regex]::Escape([string]$popup.PopupId) + '\b')
    })
    $routingFp = [string]$Target.RoutingFingerprint
    $notificationFp = [string]$popup.NotificationFingerprint

    $allReady = @($events | Where-Object {
        [string]$_.eventName -eq 'poll-activation-ready'
    })
    $ready = @($allReady | Where-Object {
        [string]$_.eventName -eq 'poll-activation-ready' -and
        (Test-EventField $_ 'notificationFp' $notificationFp) -and
        (Test-EventField $_ 'routingFp' $routingFp)
    })
    $activationFp = if ($ready.Count -eq 1 -and
        $ready[0].fields.PSObject.Properties['activationFp']) {
        [string]$ready[0].fields.activationFp
    } else {
        ''
    }
    # MainForm's route-row-activation-* records are request-scoped but do not
    # carry RouteAdapter's activationFp. Requiring exactly one activation-ready
    # record in the click window isolates that request before joining its unique
    # row requestFp chain below.
    $activationWindowIsolated = $allReady.Count -eq 1 -and
        $ready.Count -eq 1 -and
        -not [string]::IsNullOrWhiteSpace($activationFp)
    $readyUtc = if ($ready.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $ready[0]
    } else {
        [DateTime]::MinValue
    }
    $rowIssued = @($events | Where-Object {
        [string]$_.eventName -eq 'route-row-activation-issued' -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $readyUtc -and
        (Test-EventField $_ 'routingFp' $routingFp)
    })
    $rowRequestFp = if ($rowIssued.Count -eq 1 -and
        $rowIssued[0].fields.PSObject.Properties['requestFp']) {
        [string]$rowIssued[0].fields.requestFp
    } else {
        ''
    }
    $history = @($events | Where-Object {
        [string]$_.eventName -eq 'route-row-activation-result' -and
        (Test-EventField $_ 'accepted' $true) -and
        (Test-EventField $_ 'rowResult' 'history-target') -and
        (Test-EventField $_ 'requestFp' $rowRequestFp) -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $readyUtc -and
        (Test-EventField $_ 'routingFp' $routingFp)
    })
    $proof = @($events | Where-Object {
        [string]$_.eventName -eq 'route-row-activation-result' -and
        (Test-EventField $_ 'accepted' $true) -and
        (Test-EventField $_ 'rowResult' 'exact-api-proof') -and
        (Test-EventField $_ 'requestFp' $rowRequestFp) -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $readyUtc -and
        (Test-EventField $_ 'routingFp' $routingFp)
    })
    $committed = @($events | Where-Object {
        [string]$_.eventName -eq 'route-row-activation-committed' -and
        (Test-EventField $_ 'requestFp' $rowRequestFp) -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $readyUtc -and
        (Test-EventField $_ 'routingFp' $routingFp) -and
        (Test-EventField $_ 'history' $true) -and
        (Test-EventField $_ 'proof' $true)
    })
    $focus = @($events | Where-Object {
        [string]$_.eventName -eq 'route-activation-focus-result' -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $readyUtc -and
        (Test-EventField $_ 'routingFp' $routingFp) -and
        (Test-EventField $_ 'focused' $true)
    })
    $confirmed = @($events | Where-Object {
        [string]$_.eventName -eq 'activate-confirmed' -and
        (Test-EventField $_ 'activationFp' $activationFp) -and
        (Test-EventField $_ 'notificationFp' $notificationFp) -and
        (Test-EventField $_ 'routingFp' $routingFp) -and
        (Test-EventField $_ 'result' 'session-url-confirmed')
    })
    $acknowledged = @($events | Where-Object {
        [string]$_.eventName -eq 'activate-result-acknowledged' -and
        (Test-EventField $_ 'activationFp' $activationFp) -and
        (Test-EventField $_ 'notificationFp' $notificationFp) -and
        (Test-EventField $_ 'result' 'session-url-confirmed')
    })
    $completed = @($events | Where-Object {
        [string]$_.eventName -eq 'poll-activate-complete' -and
        (Test-EventField $_ 'activationFp' $activationFp) -and
        (Test-EventField $_ 'notificationFp' $notificationFp) -and
        (Test-EventField $_ 'result' 'session-url-confirmed')
    })
    $issuedUtc = if ($rowIssued.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $rowIssued[0]
    } else { [DateTime]::MinValue }
    $historyUtc = if ($history.Count -gt 0) {
        ConvertTo-EventUtc -EventRecord @(
            $history | Sort-Object { ConvertTo-EventUtc -EventRecord $_ }
        )[0]
    } else { [DateTime]::MinValue }
    $proofUtc = if ($proof.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $proof[0]
    } else { [DateTime]::MinValue }
    $committedUtc = if ($committed.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $committed[0]
    } else { [DateTime]::MinValue }
    $confirmedUtc = if ($confirmed.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $confirmed[0]
    } else { [DateTime]::MinValue }
    $acknowledgedUtc = if ($acknowledged.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $acknowledged[0]
    } else { [DateTime]::MinValue }
    $completedUtc = if ($completed.Count -eq 1) {
        ConvertTo-EventUtc -EventRecord $completed[0]
    } else { [DateTime]::MinValue }
    $activationEventOrderValid =
        $readyUtc -ne [DateTime]::MinValue -and
        $readyUtc -le $issuedUtc -and
        $issuedUtc -le $historyUtc -and
        $historyUtc -le $proofUtc -and
        $proofUtc -le $committedUtc -and
        $committedUtc -le $confirmedUtc -and
        $confirmedUtc -le $acknowledgedUtc -and
        $acknowledgedUtc -le $completedUtc

    $fallbacks = @($events | Where-Object {
        [string]$_.eventName -eq 'route-row-activation-fallback' -and
        (Test-EventField $_ 'routingFp' $routingFp)
    })
    $fallbackReasons = @($fallbacks | ForEach-Object {
        if ($_.fields.PSObject.Properties['reason']) {
            [string]$_.fields.reason
        }
    })
    $invalidFallback = @($fallbackReasons | Where-Object {
        $_ -ne 'row-unavailable-source-unchanged'
    })
    if ($fallbacks.Count -gt 1 -or $invalidFallback.Count -gt 0) {
        [void]$failures.Add('FRESH_NAV_FALLBACK_POLICY_VIOLATION')
    }

    $navigationStarts = @($events | Where-Object {
        [string]$_.eventName -eq 'route-navigation-starting'
    })
    if (($fallbacks.Count -eq 0 -and $navigationStarts.Count -gt 0) -or
        ($fallbacks.Count -eq 1 -and $navigationStarts.Count -ne 1)) {
        [void]$failures.Add('FRESH_NAV_FALLBACK_COUNT_INVALID')
    }
    $documentReady = @($events | Where-Object {
        [string]$_.eventName -eq 'route-document-ready' -and
        (Test-EventField $_ 'accepted' $true)
    })
    $explicitOpenEvents = @($events | Where-Object {
        [string]$_.eventName -eq 'route-intent-accepted' -or
        ([string]$_.eventName -in @(
            'route-observation-queued',
            'route-observation-applied') -and
            (Test-EventField $_ 'explicitOpen' $true)) -or
        ([string]$_.eventName -eq 'explicit-open-admission' -and
            (Test-EventField $_ 'accepted' $true))
    })

    $feedback = @($brokerLines | Where-Object {
        $_ -match ('broker-activation-feedback\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) + '\s+watchdogMs=20000\b')
    })
    $workerFocused = @($brokerLines | Where-Object {
        $_ -match ('broker-exact-worker-complete\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) +
            '\s+mode=activate\s+decision=focused\s+result=pending\b')
    })
    $workerHandled = @($brokerLines | Where-Object {
        $_ -match ('broker-exact-worker-complete\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) +
            '\s+mode=activate\s+decision=handled\s+result=session-url-confirmed\b')
    })
    $workerComplete = @($workerFocused + $workerHandled)
    $terminalFocused = @($brokerLines | Where-Object {
        $_ -match ('broker-popup-terminal\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) +
            '\s+outcome=focused\b')
    })
    $terminalHandled = @($brokerLines | Where-Object {
        $_ -match ('broker-popup-terminal\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) +
            '\s+outcome=handled\b')
    })
    $terminal = @($terminalFocused + $terminalHandled)
    $closed = @($brokerLines | Where-Object {
        $_ -match ('broker-closed\s+popupId=' +
            [regex]::Escape([string]$popup.PopupId) + '\b')
    })

    $afterState = Get-LatestStableRouteState -WaitSeconds 3
    $afterGeneration = if ($null -eq $afterState) {
        [long]::MinValue
    } else {
        [long]$afterState.DocumentGeneration
    }
    $bindingAfter = Read-TargetBindingInvariant -Target $Target
    $surfaceAfter = Get-BindingSurfaceInvariant

    if ($ready.Count -ne 1) { [void]$failures.Add('POLL_READY_COUNT_INVALID') }
    if ([string]::IsNullOrWhiteSpace($activationFp)) {
        [void]$failures.Add('ACTIVATION_FINGERPRINT_MISSING')
    }
    if (-not $activationWindowIsolated) {
        [void]$failures.Add('ACTIVATION_WINDOW_NOT_ISOLATED')
    }
    if ($confirmed.Count -ne 1) { [void]$failures.Add('ACTIVATE_CONFIRM_COUNT_INVALID') }
    if ($acknowledged.Count -ne 1) { [void]$failures.Add('ACTIVATE_ACK_COUNT_INVALID') }
    if ($completed.Count -ne 1) { [void]$failures.Add('POLL_COMPLETE_COUNT_INVALID') }
    if ($focus.Count -ne 1) { [void]$failures.Add('FOCUS_RECEIPT_MISSING') }
    if ($feedback.Count -ne 1) { [void]$failures.Add('BROKER_READY_WATCHDOG_INVALID') }
    if ($workerComplete.Count -ne 1) { [void]$failures.Add('BROKER_FOCUSED_OR_HANDLED_COUNT_INVALID') }
    if ($terminal.Count -ne 1) { [void]$failures.Add('BROKER_TERMINAL_COUNT_INVALID') }
    if ($closed.Count -ne 1) { [void]$failures.Add('BROKER_CLOSE_COUNT_INVALID') }

    if (-not $RestorationOnly) {
        if ($rowIssued.Count -ne 1) { [void]$failures.Add('ROW_CLICK_RECEIPT_MISSING') }
        if ($history.Count -lt 1) { [void]$failures.Add('SAME_DOCUMENT_HISTORY_TARGET_MISSING') }
        if ($proof.Count -ne 1) { [void]$failures.Add('EXACT_SESSION_GET_PROOF_MISSING') }
        if ($committed.Count -ne 1) { [void]$failures.Add('ROW_ACTIVATION_COMMIT_MISSING') }
        if (-not $activationEventOrderValid) {
            [void]$failures.Add('ACTIVATION_EVENT_ORDER_INVALID')
        }
        if ($fallbacks.Count -ne 0) { [void]$failures.Add('UNEXPECTED_FRESH_NAV_FALLBACK') }
        if ($navigationStarts.Count -ne 0) { [void]$failures.Add('FRESH_DOCUMENT_NAVIGATION_OBSERVED') }
        if ($documentReady.Count -ne 0) { [void]$failures.Add('NEW_DOCUMENT_READY_OBSERVED') }
        if ($beforeGeneration -ne $afterGeneration) {
            [void]$failures.Add('DOCUMENT_GENERATION_CHANGED')
        }
        foreach ($eventRecord in @($rowIssued + $history + $proof + $committed + $focus)) {
            $generation = Get-EventDocumentGeneration -EventRecord $eventRecord
            if ($generation -ne [long]::MinValue -and
                $generation -ne $beforeGeneration) {
                [void]$failures.Add('CORRELATED_DOCUMENT_GENERATION_CHANGED')
                break
            }
        }
        if ($explicitOpenEvents.Count -ne 0) {
            [void]$failures.Add('SYNTHETIC_CLICK_CREATED_EXPLICIT_OPEN')
        }
        if (-not (Test-BindingInvariantEqual $bindingBefore $bindingAfter)) {
            [void]$failures.Add('TARGET_BINDING_CHANGED')
        }
        if ($surfaceBefore.Count -ne $surfaceAfter.Count -or
            $surfaceBefore.Fingerprint -ne $surfaceAfter.Fingerprint) {
            [void]$failures.Add('EXPLICIT_BINDING_SURFACE_CHANGED')
        }
    }

    if ($null -eq $afterState -or
        [string]$afterState.RoutingFingerprint -ne $routingFp) {
        [void]$failures.Add('TARGET_SESSION_NOT_RENDERED')
    }
    if (-not [string]::IsNullOrWhiteSpace($script:IdentityViolation) -and
        -not $failures.Contains($script:IdentityViolation)) {
        [void]$failures.Add($script:IdentityViolation)
    }

    $popupElapsedMs = -1
    if ($closed.Count -gt 0) {
        $popupElapsedMs = [int]((ConvertTo-BrokerLineUtc -Line $closed[-1]) -
            $clickAtUtc).TotalMilliseconds
    }
    if ($workerFocused.Count -eq 1 -and
        ($popupElapsedMs -lt 0 -or $popupElapsedMs -gt 2000)) {
        [void]$failures.Add('FOCUSED_POPUP_CLOSE_EXCEEDED_2S')
    }

    $handled = $confirmed.Count -eq 1 -and
        $workerComplete.Count -eq 1 -and
        $closed.Count -eq 1
    return [pscustomobject]@{
        Step                       = $StepName
        Ok                         = $failures.Count -eq 0
        Handled                    = $handled
        Failures                   = $failures.ToArray()
        PopupId                    = [string]$popup.PopupId
        NotificationFp             = $notificationFp
        RoutingFp                  = $routingFp
        BeforeDocumentGeneration   = $beforeGeneration
        AfterDocumentGeneration    = $afterGeneration
        RowClickReceiptCount       = $rowIssued.Count
        HistoryReceiptCount        = $history.Count
        SessionGetProofCount       = $proof.Count
        ExplicitOpenEventCount     = $explicitOpenEvents.Count
        NavigationStartingCount    = $navigationStarts.Count
        FreshFallbackCount         = $fallbacks.Count
        BindingCountBefore         = $surfaceBefore.Count
        BindingCountAfter          = $surfaceAfter.Count
        IdentitySamples            = $script:IdentitySamples - $sampleCountBefore
        ElapsedMs                  = $elapsedMs
        PopupElapsedMs             = $popupElapsedMs
        PopupOutcome               = if ($workerFocused.Count -eq 1) {
            'focused'
        } else { 'handled' }
    }
}

function Invoke-RecoveryFailureTimingCheck {
    $failures = [System.Collections.Generic.List[string]]::new()
    $notificationId = [Guid]::NewGuid().ToString('D')
    $notificationFp = Get-SafeFingerprint -Value $notificationId
    $recoveryTicketId = [Guid]::NewGuid().ToString('N')
    [void]$script:NotificationFingerprints.Add($notificationFp)
    $postedAtUtc = [DateTime]::UtcNow
    $payload = [ordered]@{
        title             = 'Dest App recovery timing'
        body              = 'Recovering exact session'
        focusTarget       = 'dest-app-e2e-recovery'
        targetFingerprint = Get-Sha256Hex -Value ('dest-app-recovery:' + $notificationId)
        stackIndex        = 0
        timeoutSeconds    = 60
        popupPlacement    = [string]$script:NotifyConfig.popupPlacement
        originKind        = 'pi-web'
        notificationId    = $notificationId
        recoveryTicketId  = $recoveryTicketId
        sessionName       = 'recovery-timing'
    }
    if (-not (Invoke-BrokerRequest -Method POST -Path '/popup' -Payload $payload)) {
        [void]$failures.Add('RECOVERY_POPUP_POST_FAILED')
        return [pscustomobject]@{
            Ok = $false; Failures = $failures.ToArray(); PopupId = ''
            NotificationFp = $notificationFp; VisibleWaitMs = -1
            FailureHintMs = -1; IdentitySamples = 0
        }
    }
    $popupId = Wait-BrokerPopup `
        -NotificationFingerprint $notificationFp `
        -NotBeforeUtc $postedAtUtc
    if ([string]::IsNullOrWhiteSpace($popupId)) {
        [void]$failures.Add('RECOVERY_POPUP_NOT_SHOWN')
        return [pscustomobject]@{
            Ok = $false; Failures = $failures.ToArray(); PopupId = ''
            NotificationFp = $notificationFp; VisibleWaitMs = -1
            FailureHintMs = -1; IdentitySamples = 0
        }
    }
    [void]$script:PopupIds.Add($popupId)

    $sampleCountBefore = $script:IdentitySamples
    if (-not (Invoke-BrokerRequest -Method POST -Path '/close' -Payload @{
        popupId = $popupId
        activate = $true
    })) {
        [void]$failures.Add('RECOVERY_POPUP_CLICK_FAILED')
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(18)
    do {
        $sample = Record-DesktopIdentitySample
        if (-not $sample.ok -and -not $failures.Contains([string]$sample.code)) {
            [void]$failures.Add([string]$sample.code)
        }
        $lines = @(Get-BrokerLines | Where-Object {
            $_ -match ('\bpopupId=' + [regex]::Escape($popupId) + '\b')
        })
        $closed = @($lines | Where-Object {
            $_ -match '^\[[^]]+\]\s+broker-closed\b'
        })
        if ($closed.Count -gt 0) { break }
        Start-Sleep -Milliseconds $SampleIntervalMilliseconds
    } while ([DateTime]::UtcNow -lt $deadline)

    $lines = @(Get-BrokerLines | Where-Object {
        $_ -match ('\bpopupId=' + [regex]::Escape($popupId) + '\b')
    })
    $feedback = @($lines | Where-Object {
        $_ -match ('broker-activation-feedback\s+popupId=' +
            [regex]::Escape($popupId) + '\s+watchdogMs=12000\b')
    })
    $terminal = @($lines | Where-Object {
        $_ -match ('broker-popup-terminal\s+popupId=' +
            [regex]::Escape($popupId) + '\s+outcome=failed\b')
    })
    $closed = @($lines | Where-Object {
        $_ -match ('broker-closed\s+popupId=' +
            [regex]::Escape($popupId) + '\b')
    })

    if ($feedback.Count -ne 1) {
        [void]$failures.Add('RECOVERING_WATCHDOG_NOT_12000MS')
    }
    if ($terminal.Count -ne 1) {
        [void]$failures.Add('RECOVERY_FAILURE_TERMINAL_COUNT_INVALID')
    }
    if ($closed.Count -ne 1) {
        [void]$failures.Add('RECOVERY_FAILURE_CLOSE_COUNT_INVALID')
    }

    $visibleWaitMs = -1
    $failureHintMs = -1
    if ($feedback.Count -eq 1 -and $terminal.Count -eq 1) {
        $feedbackUtc = ConvertTo-BrokerLineUtc -Line $feedback[0]
        $terminalUtc = ConvertTo-BrokerLineUtc -Line $terminal[0]
        $visibleWaitMs = [int]($terminalUtc - $feedbackUtc).TotalMilliseconds
        if ($visibleWaitMs -lt 0 -or $visibleWaitMs -gt 12500) {
            [void]$failures.Add('RECOVERY_VISIBLE_WAIT_EXCEEDED_12S')
        }
    }
    if ($terminal.Count -eq 1 -and $closed.Count -eq 1) {
        $terminalUtc = ConvertTo-BrokerLineUtc -Line $terminal[0]
        $closedUtc = ConvertTo-BrokerLineUtc -Line $closed[-1]
        $failureHintMs = [int]($closedUtc - $terminalUtc).TotalMilliseconds
        if ($failureHintMs -lt 2000 -or $failureHintMs -gt 3500) {
            [void]$failures.Add('FAILURE_HINT_DURATION_OUTSIDE_2_TO_3S')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:IdentityViolation) -and
        -not $failures.Contains($script:IdentityViolation)) {
        [void]$failures.Add($script:IdentityViolation)
    }
    return [pscustomobject]@{
        Ok              = $failures.Count -eq 0
        Failures        = $failures.ToArray()
        PopupId         = $popupId
        NotificationFp  = $notificationFp
        VisibleWaitMs   = $visibleWaitMs
        FailureHintMs   = $failureHintMs
        IdentitySamples = $script:IdentitySamples - $sampleCountBefore
    }
}

function Get-SafeRouteEvidence {
    if ([string]::IsNullOrWhiteSpace($script:RouteLog) -or
        $script:DesktopPid -le 0) { return @() }
    $interesting = @(
        'poll-activation-ready',
        'route-activation-ui-start',
        'route-row-activation-issued',
        'route-row-activation-result',
        'route-row-binding-diagnostic',
        'route-row-activation-provisional-focus',
        'route-row-activation-progress',
        'activate-progress-result',
        'route-row-activation-committed',
        'route-row-activation-fallback-check',
        'route-row-activation-fallback',
        'route-history-changed',
        'route-session-proof',
        'route-navigation-starting',
        'route-document-ready',
        'route-intent-accepted',
        'explicit-open-admission',
        'route-observation-queued',
        'route-observation-applied',
        'route-activation-focus-result',
        'activate-confirmed',
        'activate-result-acknowledged',
        'poll-activate-complete')
    return @(Get-RouteEvents -Path $script:RouteLog -Tail 6000 | Where-Object {
        [int]$_.processId -eq $script:DesktopPid -and
        ([string]::IsNullOrWhiteSpace($script:DesktopRunId) -or
            [string]$_.runId -eq $script:DesktopRunId) -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $script:StartedAtUtc.AddSeconds(-2) -and
        [string]$_.eventName -in $interesting
    } | Select-Object -Last 80 | ForEach-Object {
        [ordered]@{
            timestamp = [string]$_.timestamp
            eventName = [string]$_.eventName
            processId = [int]$_.processId
            runId     = [string]$_.runId
            fields    = $_.fields
        }
    })
}

function Get-SafeBrokerEvidence {
    $patterns = [System.Collections.Generic.List[string]]::new()
    foreach ($popupId in $script:PopupIds) {
        if (-not [string]::IsNullOrWhiteSpace($popupId)) {
            [void]$patterns.Add('\bpopupId=' + [regex]::Escape($popupId) + '\b')
        }
    }
    foreach ($notificationFp in $script:NotificationFingerprints) {
        if (-not [string]::IsNullOrWhiteSpace($notificationFp)) {
            [void]$patterns.Add('\bnotificationFp=' +
                [regex]::Escape($notificationFp) + '\b')
        }
    }
    if ($patterns.Count -eq 0) { return @() }
    return @(Get-BrokerLines | Where-Object {
        $line = $_
        @($patterns | Where-Object { $line -match $_ }).Count -gt 0
    } | Select-Object -Last 80)
}

function Get-CurrentRouteCandidate {
    param(
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$RoutingFingerprint
    )

    $candidateMatches = @($Candidates | Where-Object {
        [string]$_.RoutingFingerprint -eq $RoutingFingerprint
    })
    if ($candidateMatches.Count -ne 1) { return $null }
    return $candidateMatches[0]
}

if (-not $ConfirmLive) {
    Write-SafeEvent -Phase 'dry-run' -Fields ([ordered]@{
        ok                 = $true
        liveExecuted       = $false
        confirmRequired    = $true
        startsOrStopsApp   = $false
        deletesSessionData = $false
        actions = @(
            'create two broker-only exact-route popups',
            'activate different captured Dest App rows automatically',
            'require same PID/HWND and same-document history plus exact GET proof',
            'prove synthetic row click creates no explicit open/binding',
            'measure recovering wait and failure auto-close',
            'restore the initially selected session in finally')
        hint = 'Run with -ConfirmLive only after the Desktop build and broker are deployed.'
    })
    exit 0
}

if ($ActivationTimeoutSeconds -lt 20 -or $ActivationTimeoutSeconds -gt 90 -or
    $PopupReadyTimeoutSeconds -lt 3 -or $PopupReadyTimeoutSeconds -gt 30 -or
    $SampleIntervalMilliseconds -lt 20 -or
    $SampleIntervalMilliseconds -gt 250) {
    Write-SafeEvent -Phase 'blocked' -Fields ([ordered]@{
        ok = $false
        code = 'INVALID_TIMEOUT_OR_SAMPLE_INTERVAL'
    })
    exit 2
}

if (-not [string]::IsNullOrWhiteSpace($StatusPath)) {
    try {
        $resolvedStatusPath = [System.IO.Path]::GetFullPath($StatusPath)
        $parent = Split-Path -Parent $resolvedStatusPath
        if ([string]::IsNullOrWhiteSpace($parent) -or
            -not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new()
        }
        $statusStream = [System.IO.File]::Open(
            $resolvedStatusPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        $statusStream.Dispose()
        $script:StatusFile = $resolvedStatusPath
    }
    catch {
        Write-SafeEvent -Phase 'blocked' -Fields ([ordered]@{
            ok = $false
            code = 'STATUS_PATH_UNAVAILABLE'
        })
        exit 2
    }
}

$caughtUnexpected = ''
try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
        [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Stop-LiveTest -Code 'RUNTIME_ROOT_UNAVAILABLE'
    }

    $windowsSessionId = (Get-Process -Id $PID).SessionId
    if ($windowsSessionId -le 0) { Stop-LiveTest -Code 'NON_INTERACTIVE_SESSION' }
    $desktopRoot = Join-Path $env:LOCALAPPDATA 'PiWebDesktop'
    $desktopSessionRoot = Join-Path $desktopRoot (
        'sessions\session-{0}' -f $windowsSessionId)
    $hostSessionRoot = Join-Path $env:LOCALAPPDATA (
        'PiNotifyRouteHost\sessions\session-{0}' -f $windowsSessionId)
    $notifyRoot = Join-Path $env:USERPROFILE '.pi-notify'
    $routeConfigPath = Join-Path $desktopRoot 'route-config.json'
    $settingsPath = Join-Path $desktopRoot 'settings.json'
    $script:RouteLog = Join-Path $desktopSessionRoot 'route.log'
    $script:PreferencesPath = Join-Path $hostSessionRoot 'route-preferences.json'
    $notifyConfigPath = Join-Path $notifyRoot 'config.json'
    $script:BrokerLog = Join-Path $notifyRoot 'logs\broker.log'

    $script:RouteConfig = Read-JsonObjectSafe `
        -Path $routeConfigPath `
        -FailureCode 'ROUTE_CONFIG_UNAVAILABLE'
    $settings = Read-JsonObjectSafe `
        -Path $settingsPath `
        -FailureCode 'SERVER_SETTINGS_UNAVAILABLE'
    $script:NotifyConfig = Read-JsonObjectSafe `
        -Path $notifyConfigPath `
        -FailureCode 'NOTIFY_CONFIG_UNAVAILABLE'
    $preferences = Read-JsonObjectSafe `
        -Path $script:PreferencesPath `
        -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'

    $instanceKey = [string]$script:RouteConfig.InstanceKey
    $adapterKey = [string]$script:RouteConfig.AdapterKey
    $profileKey = [string]$script:RouteConfig.ProfileKey
    $serverUrl = [string]$settings.ServerUrl
    $script:BrokerPort = [int]$script:NotifyConfig.brokerPort
    if ([string]::IsNullOrWhiteSpace($instanceKey) -or
        [string]::IsNullOrWhiteSpace($adapterKey) -or
        [string]::IsNullOrWhiteSpace($profileKey) -or
        [string]::IsNullOrWhiteSpace($serverUrl) -or
        $script:BrokerPort -lt 1 -or $script:BrokerPort -gt 65535) {
        Stop-LiveTest -Code 'RUNTIME_CONFIG_INVALID'
    }

    $script:DesktopPath = Resolve-DesktopExecutable -RequestedPath $DesktopExe
    $allDesktop = @(Get-DesktopProcesses)
    $desktop = @(Get-DesktopProcesses -ExactPath $script:DesktopPath)
    if ($allDesktop.Count -ne 1 -or $desktop.Count -ne 1) {
        Stop-LiveTest -Code 'DESKTOP_MUST_ALREADY_BE_SINGLE_RUNNING_INSTANCE'
    }
    $desktop[0].Refresh()
    $script:DesktopPid = [int]$desktop[0].Id
    $script:DesktopHwnd = [long]$desktop[0].MainWindowHandle
    $rootWindows = @([DestAppE2EWindowProbe]::GetVisibleRootWindows(
        $script:DesktopPid) | ForEach-Object { [long]$_ })
    if ($script:DesktopHwnd -eq 0 -or $rootWindows.Count -ne 1 -or
        $rootWindows[0] -ne $script:DesktopHwnd) {
        Stop-LiveTest -Code 'DESKTOP_SINGLE_ROOT_WINDOW_REQUIRED'
    }

    $latestDesktopEvents = @(Get-RouteEvents -Path $script:RouteLog -Tail 6000 |
        Where-Object { [int]$_.processId -eq $script:DesktopPid } |
        Sort-Object { ConvertTo-EventUtc -EventRecord $_ })
    if ($latestDesktopEvents.Count -eq 0) {
        Stop-LiveTest -Code 'DESKTOP_ROUTE_LOG_EMPTY'
    }
    $script:DesktopRunId = [string]$latestDesktopEvents[-1].runId
    if ([string]::IsNullOrWhiteSpace($script:DesktopRunId)) {
        Stop-LiveTest -Code 'DESKTOP_RUN_ID_UNAVAILABLE'
    }
    $initialState = Get-LatestStableRouteState -WaitSeconds 10
    if ($null -eq $initialState) {
        Stop-LiveTest -Code 'CURRENT_SESSION_UNAVAILABLE'
    }

    $installedCommon = Join-Path $notifyRoot 'bin\NotifyBridge.Common.ps1'
    $commonPath = if (Test-Path -LiteralPath $installedCommon -PathType Leaf) {
        $installedCommon
    } else {
        Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'
    }
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
        Stop-LiveTest -Code 'NOTIFY_COMMON_UNAVAILABLE'
    }
    . $commonPath
    [void](Set-NotifyBridgeActiveConfigPath -ConfigPath $notifyConfigPath)
    $script:NotifyRuntimeConfig = ConvertTo-NotifyBridgeHashtable `
        -InputObject $script:NotifyConfig

    if (-not (Invoke-BrokerRequest -Method GET -Path '/health')) {
        Stop-LiveTest -Code 'BROKER_HEALTH_FAILED'
    }

    try {
        $serverUri = [Uri]$serverUrl
        if (-not $serverUri.IsAbsoluteUri -or
            $serverUri.Scheme -notin @('http', 'https') -or
            -not [string]::IsNullOrEmpty($serverUri.UserInfo)) {
            Stop-LiveTest -Code 'SERVER_SETTINGS_UNAVAILABLE'
        }
        $sessionsApiUri = [UriBuilder]::new($serverUri)
        $sessionsApiUri.Path = '/api/sessions'
        $sessionsApiUri.Query = ''
        $sessionsApiUri.Fragment = ''
        $sessionResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $sessionsApiUri.Uri.AbsoluteUri `
            -TimeoutSec 15
        $apiSessions = @(if ($sessionResponse.PSObject.Properties['sessions']) {
            $sessionResponse.sessions
        } else {
            $sessionResponse
        })
    }
    catch {
        Stop-LiveTest -Code 'SESSION_API_UNAVAILABLE'
    }
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($session in $apiSessions) {
        if (-not $session.PSObject.Properties['id']) { continue }
        $sessionId = [string]$session.id
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $routingKey = Get-PiWebRoutingKey `
            -InstanceKey $instanceKey `
            -SessionId $sessionId
        $routingFp = Get-SafeFingerprint -Value $routingKey
        $bindingId = Get-RouteBindingId `
            -InstanceKey $instanceKey `
            -RoutingKey $routingKey
        $binding = Get-BindingEntry `
            -Preferences $preferences `
            -BindingId $bindingId `
            -RouteConfig $script:RouteConfig
        if ($null -eq $binding) { continue }
        $modified = [DateTime]::MinValue
        if ($session.PSObject.Properties['modified']) {
            try {
                $modified = [DateTimeOffset]::Parse(
                    [string]$session.modified).UtcDateTime
            } catch {}
        }
        [void]$candidates.Add([pscustomobject]@{
            SessionId          = $sessionId
            RoutingKey         = $routingKey
            RoutingFingerprint = $routingFp
            BindingId          = $bindingId
            ModifiedUtc        = $modified
        })
    }
    if ($candidates.Count -lt 2) {
        Stop-LiveTest -Code 'TWO_BOUND_DEST_SESSIONS_REQUIRED'
    }
    $script:OriginalTarget = Get-CurrentRouteCandidate `
        -Candidates $candidates.ToArray() `
        -RoutingFingerprint ([string]$initialState.RoutingFingerprint)
    if ($null -eq $script:OriginalTarget) {
        Stop-LiveTest -Code 'CURRENT_BINDING_AMBIGUOUS'
    }
    $script:OriginalBindingInvariant = Read-TargetBindingInvariant `
        -Target $script:OriginalTarget
    if ($null -eq $script:OriginalBindingInvariant) {
        Stop-LiveTest -Code 'ORIGINAL_BINDING_UNAVAILABLE'
    }
    $script:OriginalBindingSurfaceInvariant = Get-BindingSurfaceInvariant

    # Fail before creating any popup unless both directions have a row that was
    # verified by a real sidebar intent plus its exact API proof in this document.
    $capturedRoutingFingerprints = @(Get-CapturedRowRoutingFingerprints `
        -DocumentGeneration ([long]$initialState.DocumentGeneration))
    if ($capturedRoutingFingerprints -notcontains
        [string]$script:OriginalTarget.RoutingFingerprint) {
        Stop-LiveTest -Code 'CURRENT_ROW_NOT_CAPTURED'
    }
    $capturedAlternates = @($candidates | Where-Object {
        [string]$_.RoutingFingerprint -ne
            [string]$script:OriginalTarget.RoutingFingerprint -and
        $capturedRoutingFingerprints -contains
            [string]$_.RoutingFingerprint
    } | Sort-Object ModifiedUtc -Descending)
    if ($capturedAlternates.Count -lt 1) {
        Stop-LiveTest -Code 'ALTERNATE_CAPTURED_ROW_UNAVAILABLE'
    }
    $otherTarget = $capturedAlternates[0]

    $baselineSample = Record-DesktopIdentitySample
    if (-not $baselineSample.ok) {
        Stop-LiveTest -Code ([string]$baselineSample.code)
    }
    $bindingSurface = $script:OriginalBindingSurfaceInvariant
    Write-SafeEvent -Phase 'preflight' -Fields ([ordered]@{
        ok                  = $true
        desktopPid          = $script:DesktopPid
        desktopHwnd         = ('0x{0:X}' -f $script:DesktopHwnd)
        desktopExeFp        = Get-SafeFingerprint -Value $script:DesktopPath
        desktopRunId        = $script:DesktopRunId
        documentGeneration  = [long]$initialState.DocumentGeneration
        originalRoutingFp   = [string]$script:OriginalTarget.RoutingFingerprint
        alternateRoutingFp  = [string]$otherTarget.RoutingFingerprint
        bindingCount        = $bindingSurface.Count
        appRestarted        = $false
    })

    $first = Invoke-LiveExactActivation `
        -Target $otherTarget `
        -StepName 'alternate-session' `
        -StackIndex 0
    [void]$script:ActivationResults.Add($first)
    foreach ($code in $first.Failures) { Add-FailureKind -Code ([string]$code) }
    Write-SafeEvent -Phase 'activation' -Fields ([ordered]@{
        ok                        = [bool]$first.Ok
        step                      = [string]$first.Step
        routingFp                 = [string]$first.RoutingFp
        notificationFp            = [string]$first.NotificationFp
        desktopPid                = $script:DesktopPid
        desktopHwnd               = ('0x{0:X}' -f $script:DesktopHwnd)
        beforeDocumentGeneration  = $first.BeforeDocumentGeneration
        afterDocumentGeneration   = $first.AfterDocumentGeneration
        rowClickReceiptCount      = $first.RowClickReceiptCount
        historyReceiptCount       = $first.HistoryReceiptCount
        sessionGetProofCount      = $first.SessionGetProofCount
        explicitOpenEventCount    = $first.ExplicitOpenEventCount
        navigationStartingCount   = $first.NavigationStartingCount
        freshFallbackCount        = $first.FreshFallbackCount
        identitySamples           = $first.IdentitySamples
        elapsedMs                 = $first.ElapsedMs
        popupElapsedMs            = $first.PopupElapsedMs
        popupOutcome              = $first.PopupOutcome
        failures                  = @($first.Failures)
    })

    if ($first.Handled) {
        $second = Invoke-LiveExactActivation `
            -Target $script:OriginalTarget `
            -StepName 'restore-original-session' `
            -StackIndex 0
        [void]$script:ActivationResults.Add($second)
        foreach ($code in $second.Failures) { Add-FailureKind -Code ([string]$code) }
        Write-SafeEvent -Phase 'activation' -Fields ([ordered]@{
            ok                        = [bool]$second.Ok
            step                      = [string]$second.Step
            routingFp                 = [string]$second.RoutingFp
            notificationFp            = [string]$second.NotificationFp
            desktopPid                = $script:DesktopPid
            desktopHwnd               = ('0x{0:X}' -f $script:DesktopHwnd)
            beforeDocumentGeneration  = $second.BeforeDocumentGeneration
            afterDocumentGeneration   = $second.AfterDocumentGeneration
            rowClickReceiptCount      = $second.RowClickReceiptCount
            historyReceiptCount       = $second.HistoryReceiptCount
            sessionGetProofCount      = $second.SessionGetProofCount
            explicitOpenEventCount    = $second.ExplicitOpenEventCount
            navigationStartingCount   = $second.NavigationStartingCount
            freshFallbackCount        = $second.FreshFallbackCount
            identitySamples           = $second.IdentitySamples
            elapsedMs                 = $second.ElapsedMs
            popupElapsedMs            = $second.PopupElapsedMs
            popupOutcome              = $second.PopupOutcome
            failures                  = @($second.Failures)
        })
    }
    else {
        Add-FailureKind -Code 'SECOND_ACTIVATION_SKIPPED_AFTER_UNHANDLED_FIRST'
    }

    $stateBeforeTiming = Get-LatestStableRouteState -WaitSeconds 3
    if ($null -ne $stateBeforeTiming -and
        [string]$stateBeforeTiming.RoutingFingerprint -eq
            [string]$script:OriginalTarget.RoutingFingerprint) {
        $script:RecoveryTimingResult = Invoke-RecoveryFailureTimingCheck
        foreach ($code in $script:RecoveryTimingResult.Failures) {
            Add-FailureKind -Code ([string]$code)
        }
        Write-SafeEvent -Phase 'recovery-timing' -Fields ([ordered]@{
            ok              = [bool]$script:RecoveryTimingResult.Ok
            notificationFp  = [string]$script:RecoveryTimingResult.NotificationFp
            visibleWaitMs   = $script:RecoveryTimingResult.VisibleWaitMs
            failureHintMs   = $script:RecoveryTimingResult.FailureHintMs
            identitySamples = $script:RecoveryTimingResult.IdentitySamples
            failures        = @($script:RecoveryTimingResult.Failures)
        })
    }
    else {
        Add-FailureKind -Code 'RECOVERY_TIMING_SKIPPED_BEFORE_RESTORE'
    }
}
catch {
    if ($_.Exception.Message -ne 'DEST_LIVE_ABORT') {
        $caughtUnexpected = $_.Exception.GetType().Name
        Add-FailureKind -Code 'UNEXPECTED_TEST_EXCEPTION'
    }
}
finally {
    # Re-discover by notification fingerprint before closing so a POST whose
    # response was lost, or whose popup became visible after the ready timeout,
    # cannot escape cleanup merely because its popupId was not returned in time.
    Close-AllTestPopups -DiscoveryWaitMilliseconds 500

    if ($null -ne $script:OriginalTarget -and
        $script:DesktopPid -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($script:DesktopPath)) {
        try {
            $identity = Record-DesktopIdentitySample
            if ($identity.ok) {
                $current = Get-LatestStableRouteState -WaitSeconds 3
                if ($null -eq $current -or
                    [string]$current.RoutingFingerprint -ne
                        [string]$script:OriginalTarget.RoutingFingerprint) {
                    $restore = Invoke-LiveExactActivation `
                        -Target $script:OriginalTarget `
                        -StepName 'finally-restore-original' `
                        -StackIndex 0 `
                        -RestorationOnly
                    if (-not $restore.Handled) {
                        Add-FailureKind -Code 'FINALLY_RESTORE_ACTIVATION_FAILED'
                    }
                }
                $restoredState = Get-LatestStableRouteState -WaitSeconds 5
                $restoredBinding = Read-TargetBindingInvariant `
                    -Target $script:OriginalTarget
                $restoredSurface = Get-BindingSurfaceInvariant
                $bindingRestored = Test-BindingInvariantEqual `
                    $script:OriginalBindingInvariant `
                    $restoredBinding
                $surfaceRestored =
                    $null -ne $script:OriginalBindingSurfaceInvariant -and
                    $script:OriginalBindingSurfaceInvariant.Count -eq
                        $restoredSurface.Count -and
                    $script:OriginalBindingSurfaceInvariant.Fingerprint -eq
                        $restoredSurface.Fingerprint
                $script:Restored = $null -ne $restoredState -and
                    [string]$restoredState.RoutingFingerprint -eq
                        [string]$script:OriginalTarget.RoutingFingerprint -and
                    $bindingRestored -and
                    $surfaceRestored
                if (-not $bindingRestored) {
                    Add-FailureKind -Code 'ORIGINAL_BINDING_NOT_RESTORED'
                }
                if (-not $surfaceRestored) {
                    Add-FailureKind -Code 'BINDING_SURFACE_NOT_RESTORED'
                }
            }
        }
        catch {
            $script:Restored = $false
        }
    }

    # A finally-time restore creates its own popup after the first cleanup
    # pass. Close the complete accumulated set again so an exception or timeout
    # during restoration cannot leave that popup behind.
    Close-AllTestPopups -DiscoveryWaitMilliseconds 500
}

if ($null -ne $script:OriginalTarget -and -not $script:Restored) {
    Add-FailureKind -Code 'ORIGINAL_SESSION_NOT_RESTORED'
}
if (-not [string]::IsNullOrWhiteSpace($script:IdentityViolation)) {
    Add-FailureKind -Code $script:IdentityViolation
}

if ($script:FailureKinds.Count -gt 0) {
    $finalSample = if ($script:DesktopPid -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($script:DesktopPath)) {
        Get-DesktopIdentitySample
    } else { $null }
    Write-SafeEvent -Phase 'failed' -Fields ([ordered]@{
        ok                  = $false
        code                = $script:FailureCode
        failureKinds        = $script:FailureKinds.ToArray()
        unexpectedType      = $caughtUnexpected
        restored            = $script:Restored
        desktopPid          = $script:DesktopPid
        desktopHwnd         = if ($script:DesktopHwnd -eq 0) {
            '0x0'
        } else {
            '0x{0:X}' -f $script:DesktopHwnd
        }
        desktopIdentity     = $finalSample
        documentGeneration  = if (
            [string]::IsNullOrWhiteSpace($script:RouteLog) -or
            $script:DesktopPid -le 0 -or
            [string]::IsNullOrWhiteSpace($script:DesktopRunId)) {
            -1
        }
        else {
            $safeCurrentState = Get-LatestStableRouteState
            if ($null -eq $safeCurrentState) {
                -1
            }
            else {
                $safeCurrentState.DocumentGeneration
            }
        }
        routeEvidence       = @(Get-SafeRouteEvidence)
        brokerEvidence      = @(Get-SafeBrokerEvidence)
    })
    exit 1
}

$finalState = Get-LatestStableRouteState -WaitSeconds 2
Write-SafeEvent -Phase 'passed' -Fields ([ordered]@{
    ok                  = $true
    restored            = $script:Restored
    desktopPid          = $script:DesktopPid
    desktopHwnd         = ('0x{0:X}' -f $script:DesktopHwnd)
    desktopRunId        = $script:DesktopRunId
    documentGeneration  = [long]$finalState.DocumentGeneration
    activationCount     = $script:ActivationResults.Count
    identitySamples     = $script:IdentitySamples
    recoveryVisibleWaitMs = $script:RecoveryTimingResult.VisibleWaitMs
    failureHintMs       = $script:RecoveryTimingResult.FailureHintMs
})
exit 0
