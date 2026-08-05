[CmdletBinding()]
param(
    [switch]$ConfirmLive,
    [string]$DesktopExe = '',
    [int]$TimeoutSeconds = 120,
    [int]$StartupTimeoutSeconds = 60,
    [int]$GracefulCloseSeconds = 8,
    [string]$StatusPath = '',
    [string]$TargetSessionId = '',
    [ValidateSet('UserInterface', 'RenderProcessExit')]
    [string]$RecoveryTrigger = 'UserInterface',
    [switch]$ActivatePopupById
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is an intentionally live test. It restarts PiWebDesktop, emits one real
# notification (including the configured QQ sink), and waits for a human or an
# external desktop controller to press Ctrl+R and click the resulting popup.
# No UI input is synthesized here.

$script:FailureCode = 'LIVE_TEST_FAILED'
$script:FailureDetail = ''
$script:SafeRoutingFingerprint = ''
$script:SafeNotificationFingerprint = ''
$script:StatusFile = ''
$resolvedTargetSessionId = $TargetSessionId
if ([string]::IsNullOrWhiteSpace($resolvedTargetSessionId) -and
    -not [string]::IsNullOrWhiteSpace($env:PI_WEB_LIVE_TARGET_SESSION_ID)) {
    $resolvedTargetSessionId = [string]$env:PI_WEB_LIVE_TARGET_SESSION_ID
}
Remove-Item Env:\PI_WEB_LIVE_TARGET_SESSION_ID -ErrorAction SilentlyContinue

function Write-LiveSafeEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][hashtable]$Fields
    )

    $record = [ordered]@{
        type  = 'pi-web-reconnect-live'
        phase = $Phase
    }
    foreach ($entry in $Fields.GetEnumerator()) {
        $record[$entry.Key] = $entry.Value
    }
    $line = $record | ConvertTo-Json -Depth 8 -Compress
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    if (-not [string]::IsNullOrWhiteSpace($script:StatusFile)) {
        [System.IO.File]::AppendAllText(
            $script:StatusFile,
            $line + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false))
    }
}

function Stop-LiveTest {
    param([Parameter(Mandatory = $true)][string]$Code)

    $script:FailureCode = $Code
    throw [System.InvalidOperationException]::new('LIVE_TEST_ABORT')
}

if (-not $ConfirmLive) {
    Write-LiveSafeEvent -Phase 'blocked' -Fields ([ordered]@{
        ok   = $false
        code = 'CONFIRM_LIVE_REQUIRED'
        hint = 'Run again with -ConfirmLive; the test restarts PiWebDesktop and emits one real notification.'
    })
    exit 2
}

if ($TimeoutSeconds -lt 30 -or $TimeoutSeconds -gt 300 -or
    $StartupTimeoutSeconds -lt 15 -or $StartupTimeoutSeconds -gt 180 -or
    $GracefulCloseSeconds -lt 2 -or $GracefulCloseSeconds -gt 30) {
    Write-LiveSafeEvent -Phase 'blocked' -Fields ([ordered]@{
        ok   = $false
        code = 'INVALID_TIMEOUT'
    })
    exit 2
}

if (-not [string]::IsNullOrWhiteSpace($StatusPath)) {
    try {
        $candidateStatusPath = [System.IO.Path]::GetFullPath($StatusPath)
        $statusParent = Split-Path -Parent $candidateStatusPath
        if ([string]::IsNullOrWhiteSpace($statusParent) -or
            -not (Test-Path -LiteralPath $statusParent -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new()
        }
        [System.IO.File]::WriteAllText(
            $candidateStatusPath,
            '',
            [System.Text.UTF8Encoding]::new($false))
        $script:StatusFile = $candidateStatusPath
    }
    catch {
        Write-LiveSafeEvent -Phase 'blocked' -Fields ([ordered]@{
            ok   = $false
            code = 'STATUS_PATH_UNAVAILABLE'
        })
        exit 2
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Value)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-SafeFingerprint {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return (Get-Sha256Hex -Value $Value).Substring(0, 16)
}

function Get-PiWebRoutingKey {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceKey,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    return Get-Sha256Hex -Value ('pi-web-route-v1' + [char]0 + $InstanceKey + [char]0 + $SessionId)
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
        $value = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value) {
            Stop-LiveTest -Code $FailureCode
        }
        return $value
    }
    catch {
        if ($_.Exception.Message -eq 'LIVE_TEST_ABORT') {
            throw
        }
        Stop-LiveTest -Code $FailureCode
    }
}

function Get-RouteEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Tail = 1800
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $events = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($line in (Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $eventRecord = $line | ConvertFrom-Json -ErrorAction Stop
                if ($eventRecord.PSObject.Properties['eventName'] -and
                    $eventRecord.PSObject.Properties['timestamp'] -and
                    $eventRecord.PSObject.Properties['processId']) {
                    [void]$events.Add($eventRecord)
                }
            }
            catch {
                # A writer may have an incomplete final line. It is retried on the next read.
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

function Get-DesktopProcesses {
    param([string]$ExactPath = '')

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'PiWebDesktop' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $currentSessionId) {
                continue
            }
            $processPath = [string]$process.Path
            if ([string]::IsNullOrWhiteSpace($processPath)) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($ExactPath) -and
                -not [string]::Equals(
                    [System.IO.Path]::GetFullPath($processPath),
                    [System.IO.Path]::GetFullPath($ExactPath),
                    [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            [void]$items.Add($process)
        }
        catch {
            # A process can exit while it is enumerated.
        }
    }
    return $items.ToArray()
}

function Invoke-DesktopRendererFailure {
    param([Parameter(Mandatory = $true)][int]$DesktopProcessId)

    $profileMarker = [Regex]::Escape(
        (Join-Path $env:LOCALAPPDATA 'PiWebDesktop\WebView2'))
    $webViewProcesses = @(Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "Name = 'msedgewebview2.exe'" `
        -ErrorAction Stop)
    $browserProcesses = @($webViewProcesses | Where-Object {
        [int]$_.ParentProcessId -eq $DesktopProcessId -and
        [string]$_.CommandLine -match $profileMarker -and
        [string]$_.CommandLine -notmatch '(?i)(?:^|\s)--type='
    })
    if ($browserProcesses.Count -ne 1) {
        Stop-LiveTest -Code 'WEBVIEW_BROWSER_AMBIGUOUS'
    }
    $browserProcessId = [int]$browserProcesses[0].ProcessId
    $rendererProcesses = @($webViewProcesses | Where-Object {
        [int]$_.ParentProcessId -eq $browserProcessId -and
        [string]$_.CommandLine -match $profileMarker -and
        [string]$_.CommandLine -match '(?i)(?:^|\s)--type=renderer(?:\s|$)'
    })
    if ($rendererProcesses.Count -ne 1) {
        Stop-LiveTest -Code 'WEBVIEW_RENDERER_AMBIGUOUS'
    }
    try {
        Stop-Process -Id ([int]$rendererProcesses[0].ProcessId) -Force -ErrorAction Stop
    }
    catch {
        Stop-LiveTest -Code 'WEBVIEW_RENDERER_STOP_FAILED'
    }
}

function Resolve-DesktopExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        try {
            $resolved = (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
            if (-not [string]::Equals(
                    [System.IO.Path]::GetExtension($resolved),
                    '.exe',
                    [StringComparison]::OrdinalIgnoreCase)) {
                Stop-LiveTest -Code 'DESKTOP_EXE_INVALID'
            }
            return [System.IO.Path]::GetFullPath($resolved)
        }
        catch {
            if ($_.Exception.Message -eq 'LIVE_TEST_ABORT') {
                throw
            }
            Stop-LiveTest -Code 'DESKTOP_EXE_INVALID'
        }
    }

    $paths = @(Get-DesktopProcesses | ForEach-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.Path) } catch { $null }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($paths.Count -ne 1) {
        Stop-LiveTest -Code 'DESKTOP_EXE_REQUIRED'
    }
    return $paths[0]
}

function Stop-DesktopProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$ExactPath,
        [Parameter(Mandatory = $true)][int]$GraceSeconds
    )

    $forced = $false
    $processes = @(Get-DesktopProcesses -ExactPath $ExactPath)
    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch {}
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-DesktopProcesses -ExactPath $ExactPath).Count -eq 0) {
            return $forced
        }
        Start-Sleep -Milliseconds 100
    }
    foreach ($process in @(Get-DesktopProcesses -ExactPath $ExactPath)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $forced = $true
        }
        catch {}
    }
    $forceDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $forceDeadline) {
        if (@(Get-DesktopProcesses -ExactPath $ExactPath).Count -eq 0) {
            return $forced
        }
        Start-Sleep -Milliseconds 100
    }
    Stop-LiveTest -Code 'DESKTOP_STOP_FAILED'
}

function New-SessionUrl {
    param(
        [Parameter(Mandatory = $true)][string]$ServerUrl,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    try {
        $builder = [UriBuilder]::new($ServerUrl)
        if ($builder.Scheme -notin @('http', 'https') -or
            [string]::IsNullOrWhiteSpace($builder.Host) -or
            -not [string]::IsNullOrWhiteSpace($builder.UserName) -or
            $ServerUrl.Contains('"')) {
            Stop-LiveTest -Code 'SERVER_SETTINGS_INVALID'
        }
        $builder.Query = 'session=' + [Uri]::EscapeDataString($SessionId)
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        if ($_.Exception.Message -eq 'LIVE_TEST_ABORT') {
            throw
        }
        Stop-LiveTest -Code 'SERVER_SETTINGS_INVALID'
    }
}

function Start-DesktopSession {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$SessionUrl
    )

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Executable
        $startInfo.Arguments = '--url "' + $SessionUrl + '"'
        $startInfo.UseShellExecute = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            Stop-LiveTest -Code 'DESKTOP_START_FAILED'
        }
        return $process
    }
    catch {
        if ($_.Exception.Message -eq 'LIVE_TEST_ABORT') {
            throw
        }
        Stop-LiveTest -Code 'DESKTOP_START_FAILED'
    }
}

function Get-LatestCurrentRouteEvent {
    param(
        [Parameter(Mandatory = $true)][string]$RouteLog,
        [Parameter(Mandatory = $true)][int[]]$ProcessIds,
        [DateTime]$NotBeforeUtc = [DateTime]::MinValue,
        [string]$ExpectedRoutingFingerprint = ''
    )

    $proofs = @(Get-RouteEvents -Path $RouteLog -Tail 5000 | Where-Object {
        $ProcessIds -contains [int]$_.processId -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $NotBeforeUtc -and
        [string]$_.eventName -eq 'route-session-proof' -and
        $_.fields -and
        $_.fields.PSObject.Properties['accepted'] -and
        [bool]$_.fields.accepted -and
        $_.fields.PSObject.Properties['routingFp'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.fields.routingFp) -and
        ([string]::IsNullOrWhiteSpace($ExpectedRoutingFingerprint) -or
            [string]$_.fields.routingFp -eq $ExpectedRoutingFingerprint)
    })
    if ($proofs.Count -gt 0) {
        return $proofs[-1]
    }

    $fallbacks = @(Get-RouteEvents -Path $RouteLog -Tail 5000 | Where-Object {
        $ProcessIds -contains [int]$_.processId -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $NotBeforeUtc -and
        [string]$_.eventName -in @('route-history-changed', 'route-navigation-completed') -and
        $_.fields -and
        $_.fields.PSObject.Properties['routingFp'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.fields.routingFp) -and
        ([string]::IsNullOrWhiteSpace($ExpectedRoutingFingerprint) -or
            [string]$_.fields.routingFp -eq $ExpectedRoutingFingerprint)
    })
    if ($fallbacks.Count -gt 0) {
        return $fallbacks[-1]
    }
    return $null
}

function Wait-DesktopTargetReady {
    param(
        [Parameter(Mandatory = $true)][string]$RouteLog,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$RoutingFingerprint,
        [Parameter(Mandatory = $true)][DateTime]$NotBeforeUtc,
        [Parameter(Mandatory = $true)][int]$WaitSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            Stop-LiveTest -Code 'DESKTOP_EXITED_DURING_STARTUP'
        }
        $events = @(Get-RouteEvents -Path $RouteLog -Tail 2500 | Where-Object {
            [int]$_.processId -eq $ProcessId -and
            (ConvertTo-EventUtc -EventRecord $_) -ge $NotBeforeUtc
        })
        $proof = @($events | Where-Object {
            [string]$_.eventName -eq 'route-session-proof' -and
            $_.fields.PSObject.Properties['accepted'] -and
            [bool]$_.fields.accepted -and
            [string]$_.fields.routingFp -eq $RoutingFingerprint
        } | Select-Object -Last 1)
        $owner = @($events | Where-Object {
            [string]$_.eventName -eq 'owner-registered' -and
            [string]$_.fields.routingFp -eq $RoutingFingerprint
        } | Select-Object -Last 1)
        if ($proof.Count -eq 1 -and $owner.Count -eq 1) {
            return [pscustomobject]@{
                ProcessId = $ProcessId
                RunId     = [string]$owner[0].runId
                OwnerFp   = [string]$owner[0].fields.ownerFp
                PageFp    = [string]$owner[0].fields.pageFp
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Stop-LiveTest -Code 'DESKTOP_TARGET_NOT_READY'
}

function Get-BindingEntry {
    param(
        [Parameter(Mandatory = $true)]$Preferences,
        [Parameter(Mandatory = $true)][string]$BindingId,
        [Parameter(Mandatory = $true)]$RouteConfig
    )

    if (-not $Preferences.PSObject.Properties['sessions'] -or $null -eq $Preferences.sessions) {
        return $null
    }
    $property = $Preferences.sessions.PSObject.Properties[$BindingId]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }
    $binding = $property.Value
    if (-not $binding.PSObject.Properties['adapterIdentity'] -or
        $null -eq $binding.adapterIdentity) {
        return $null
    }
    $identity = $binding.adapterIdentity
    if ([string]$identity.adapterKind -ne 'pi-web-desktop' -or
        [string]$identity.profileKey -ne [string]$RouteConfig.ProfileKey -or
        [string]$binding.adapterKey -ne [string]$RouteConfig.AdapterKey) {
        return $null
    }
    return $binding
}

function Get-BindingInvariant {
    param([Parameter(Mandatory = $true)]$Binding)

    return [pscustomobject]@{
        adapterKey  = [string]$Binding.adapterKey
        openEventId = [string]$Binding.openEventId
        openedAtMs  = [string]$Binding.openedAtMs
        revision    = [string]$Binding.revision
    }
}

function Test-BindingInvariantEqual {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    return [string]$Before.adapterKey -eq [string]$After.adapterKey -and
        [string]$Before.openEventId -eq [string]$After.openEventId -and
        [string]$Before.openedAtMs -eq [string]$After.openedAtMs -and
        [string]$Before.revision -eq [string]$After.revision
}

function Get-CorrelatedLogLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [int]$Tail = 2500
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    try {
        return @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop |
            Where-Object { $_ -like ('*' + $Needle + '*') })
    }
    catch {
        return @()
    }
}

function Get-LogLinesAfterMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Marker,
        [int]$Tail = 2500
    )

    if ([string]::IsNullOrWhiteSpace($Marker) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    try {
        $lines = @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop)
        $markerIndex = -1
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ([string]$lines[$index] -eq $Marker) {
                $markerIndex = $index
                break
            }
        }
        if ($markerIndex -lt 0 -or $markerIndex -ge ($lines.Count - 1)) {
            return @()
        }
        return @($lines[($markerIndex + 1)..($lines.Count - 1)])
    }
    catch {
        return @()
    }
}

function Get-RegexCount {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    return @($Lines | Where-Object { $_ -match $Pattern }).Count
}

function Invoke-LiveNotification {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$NotificationFingerprint,
        [Parameter(Mandatory = $true)][string]$InstanceKey,
        [Parameter(Mandatory = $true)][string]$RoutingKey,
        [Parameter(Mandatory = $true)][int]$RequestTimeoutSeconds
    )

    $safeSuffix = $NotificationFingerprint.Substring(0, 8)
    $payload = [ordered]@{
        title            = '[自动回归 ' + $safeSuffix + '] Pi Web 重连'
        body             = '点击后应回到重连前的对应会话'
        routeVersion     = 1
        notificationId   = $NotificationId
        notificationKind = 'turn-complete'
        originKind       = 'pi-web'
        instanceKey      = $InstanceKey
        routingKey       = $RoutingKey
    }
    try {
        $headers = @{ 'X-Pi-Notify-Token' = $Token }
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Method Post `
            -Uri ('http://127.0.0.1:{0}/notify' -f $Port) `
            -Headers $headers `
            -ContentType 'application/json; charset=utf-8' `
            -Body ($payload | ConvertTo-Json -Depth 5 -Compress) `
            -TimeoutSec $RequestTimeoutSeconds
        if ([int]$response.StatusCode -ne 200) {
            Stop-LiveTest -Code 'NOTIFICATION_POST_REJECTED'
        }
    }
    catch {
        if ($_.Exception.Message -eq 'LIVE_TEST_ABORT') {
            throw
        }
        Stop-LiveTest -Code 'NOTIFICATION_POST_FAILED'
    }
}

function Close-TestPopupSafe {
    param(
        [int]$BrokerPort,
        [string]$PopupId,
        [bool]$Activate = $false
    )

    if ($BrokerPort -lt 1 -or [string]::IsNullOrWhiteSpace($PopupId)) {
        return $false
    }
    try {
        $payload = @{ popupId = $PopupId; activate = $Activate } | ConvertTo-Json -Compress
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Method Post `
            -Uri ('http://127.0.0.1:{0}/close' -f $BrokerPort) `
            -ContentType 'application/json; charset=utf-8' `
            -Body $payload `
            -TimeoutSec 3
        return [int]$response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

$startedAtUtc = [DateTime]::UtcNow
$success = $false
$desktopExePath = ''
$targetUrl = ''
$targetRoutingKey = ''
$targetSessionId = ''
$targetBindingId = ''
$routeLog = ''
$bindingPath = ''
$listenerLog = ''
$brokerLog = ''
$brokerPort = 0
$originalWasRunning = $false
$testDesktopProcess = $null
$testDesktopReady = $null
$forcedOriginalClose = $false
$popupId = ''
$popupQueueMarker = ''
$popupClicked = $false
$popupClosedDuringCleanup = $false
$processRestored = $false
$bindingUnchanged = $false
$ownerIdentityRotated = $false
$pendingRecoveryObserved = $false
$injectedBeforeRestore = $false
$injectionEventName = ''
$notificationPostedAtUtc = [DateTime]::MinValue
$recoveryIssuedAtUtc = [DateTime]::MinValue
$recoveryRestoredAtUtc = [DateTime]::MinValue
$desktopCounts = [ordered]@{}
$brokerCounts = [ordered]@{}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
        [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Stop-LiveTest -Code 'RUNTIME_ROOT_UNAVAILABLE'
    }

    $windowsSessionId = (Get-Process -Id $PID).SessionId
    $desktopRoot = Join-Path $env:LOCALAPPDATA 'PiWebDesktop'
    $desktopSessionRoot = Join-Path $desktopRoot ('sessions\session-{0}' -f $windowsSessionId)
    $hostSessionRoot = Join-Path $env:LOCALAPPDATA ('PiNotifyRouteHost\sessions\session-{0}' -f $windowsSessionId)
    $notifyRoot = Join-Path $env:USERPROFILE '.pi-notify'
    $routeConfigPath = Join-Path $desktopRoot 'route-config.json'
    $settingsPath = Join-Path $desktopRoot 'settings.json'
    $routeLog = Join-Path $desktopSessionRoot 'route.log'
    $bindingPath = Join-Path $hostSessionRoot 'route-preferences.json'
    $notifyConfigPath = Join-Path $notifyRoot 'config.json'
    $listenerLog = Join-Path $notifyRoot 'logs\listener.log'
    $brokerLog = Join-Path $notifyRoot 'logs\broker.log'

    $routeConfig = Read-JsonObjectSafe -Path $routeConfigPath -FailureCode 'ROUTE_CONFIG_UNAVAILABLE'
    $settings = Read-JsonObjectSafe -Path $settingsPath -FailureCode 'SERVER_SETTINGS_UNAVAILABLE'
    $notifyConfig = Read-JsonObjectSafe -Path $notifyConfigPath -FailureCode 'NOTIFY_CONFIG_UNAVAILABLE'
    $preferences = Read-JsonObjectSafe -Path $bindingPath -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'

    $instanceKey = [string]$routeConfig.InstanceKey
    $adapterKey = [string]$routeConfig.AdapterKey
    $profileKey = [string]$routeConfig.ProfileKey
    $serverUrl = [string]$settings.ServerUrl
    $notifyToken = [string]$notifyConfig.token
    $listenerPort = [int]$notifyConfig.port
    $brokerPort = [int]$notifyConfig.brokerPort
    if ([string]::IsNullOrWhiteSpace($instanceKey) -or
        [string]::IsNullOrWhiteSpace($adapterKey) -or
        [string]::IsNullOrWhiteSpace($profileKey) -or
        [string]::IsNullOrWhiteSpace($serverUrl) -or
        [string]::IsNullOrWhiteSpace($notifyToken) -or
        $listenerPort -lt 1 -or $listenerPort -gt 65535 -or
        $brokerPort -lt 1 -or $brokerPort -gt 65535) {
        Stop-LiveTest -Code 'RUNTIME_CONFIG_INVALID'
    }

    $desktopExePath = Resolve-DesktopExecutable -RequestedPath $DesktopExe
    $otherDesktopBuilds = @(Get-DesktopProcesses | Where-Object {
        try {
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$_.Path),
                $desktopExePath,
                [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $true
        }
    })
    if ($otherDesktopBuilds.Count -gt 0) {
        Stop-LiveTest -Code 'OTHER_DESKTOP_BUILD_RUNNING'
    }
    $originalProcesses = @(Get-DesktopProcesses -ExactPath $desktopExePath)
    if ($originalProcesses.Count -gt 1) {
        Stop-LiveTest -Code 'MULTIPLE_DESKTOP_PROCESSES'
    }
    $originalWasRunning = $originalProcesses.Count -eq 1

    $currentRoutingFingerprint = ''
    if ($originalWasRunning) {
        $currentEvent = Get-LatestCurrentRouteEvent `
            -RouteLog $routeLog `
            -ProcessIds @([int]$originalProcesses[0].Id)
        if ($null -eq $currentEvent) {
            Stop-LiveTest -Code 'CURRENT_SESSION_UNAVAILABLE'
        }
        $currentRoutingFingerprint = [string]$currentEvent.fields.routingFp
    }

    $target = $null
    if (-not [string]::IsNullOrWhiteSpace($resolvedTargetSessionId)) {
        if ($resolvedTargetSessionId.Length -gt 256 -or
            $resolvedTargetSessionId.Contains('://') -or
            $resolvedTargetSessionId -match '[\u0000-\u001f\u007f-\u009f\ufeff]') {
            Stop-LiveTest -Code 'TARGET_SESSION_INVALID'
        }
        $routingKey = Get-PiWebRoutingKey `
            -InstanceKey $instanceKey `
            -SessionId $resolvedTargetSessionId
        $routingFingerprint = Get-SafeFingerprint -Value $routingKey
        $bindingId = Get-RouteBindingId `
            -InstanceKey $instanceKey `
            -RoutingKey $routingKey
        $binding = Get-BindingEntry `
            -Preferences $preferences `
            -BindingId $bindingId `
            -RouteConfig $routeConfig
        if ($null -eq $binding) {
            Stop-LiveTest -Code 'TARGET_SESSION_UNBOUND'
        }
        $target = [pscustomobject]@{
            SessionId          = $resolvedTargetSessionId
            RoutingKey         = $routingKey
            RoutingFingerprint = $routingFingerprint
            BindingId          = $bindingId
            Binding            = $binding
            ModifiedUtc        = [DateTime]::MinValue
        }
    }
    else {
        try {
            $sessionResponse = Invoke-RestMethod `
                -Method Get `
                -Uri ($serverUrl.TrimEnd('/') + '/api/sessions') `
                -TimeoutSec 15
            # Wrap the whole conditional so PowerShell cannot unwrap a one-item
            # response into a scalar under StrictMode.
            $apiSessions = @(if ($sessionResponse.PSObject.Properties['sessions']) {
                $sessionResponse.sessions
            }
            else {
                $sessionResponse
            })
        }
        catch {
            Stop-LiveTest -Code 'SESSION_API_UNAVAILABLE'
        }
        if ($apiSessions.Count -eq 0) {
            Stop-LiveTest -Code 'SESSION_API_EMPTY'
        }

        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($session in $apiSessions) {
            if (-not $session.PSObject.Properties['id']) {
                continue
            }
            $rawSessionId = [string]$session.id
            if ([string]::IsNullOrWhiteSpace($rawSessionId)) {
                continue
            }
            $routingKey = Get-PiWebRoutingKey -InstanceKey $instanceKey -SessionId $rawSessionId
            $routingFingerprint = Get-SafeFingerprint -Value $routingKey
            $bindingId = Get-RouteBindingId -InstanceKey $instanceKey -RoutingKey $routingKey
            $binding = Get-BindingEntry -Preferences $preferences -BindingId $bindingId -RouteConfig $routeConfig
            if ($null -eq $binding) {
                continue
            }
            $modified = [DateTime]::MinValue
            if ($session.PSObject.Properties['modified']) {
                try { $modified = [DateTimeOffset]::Parse([string]$session.modified).UtcDateTime } catch {}
            }
            [void]$candidates.Add([pscustomobject]@{
                SessionId          = $rawSessionId
                RoutingKey         = $routingKey
                RoutingFingerprint = $routingFingerprint
                BindingId          = $bindingId
                Binding            = $binding
                ModifiedUtc        = $modified
            })
        }
        if ($candidates.Count -eq 0) {
            Stop-LiveTest -Code 'NO_BOUND_SESSION'
        }

        if ($originalWasRunning) {
            $currentCandidates = @($candidates | Where-Object {
                $_.RoutingFingerprint -eq $currentRoutingFingerprint
            })
            if ($currentCandidates.Count -ne 1) {
                Stop-LiveTest -Code 'CURRENT_BINDING_AMBIGUOUS'
            }
            $target = $currentCandidates[0]
        }
        else {
            $target = @($candidates | Sort-Object ModifiedUtc -Descending | Select-Object -First 1)[0]
        }
    }

    $targetSessionId = [string]$target.SessionId
    $targetRoutingKey = [string]$target.RoutingKey
    $targetBindingId = [string]$target.BindingId
    $script:SafeRoutingFingerprint = [string]$target.RoutingFingerprint
    $targetUrl = New-SessionUrl -ServerUrl $serverUrl -SessionId $targetSessionId

    $notificationId = [Guid]::NewGuid().ToString('D')
    $script:SafeNotificationFingerprint = Get-SafeFingerprint -Value $notificationId

    Write-LiveSafeEvent -Phase 'preparing' -Fields ([ordered]@{
        ok             = $true
        routingFp      = $script:SafeRoutingFingerprint
        notificationFp = $script:SafeNotificationFingerprint
        originalRunning = $originalWasRunning
    })

    if ($originalWasRunning) {
        $forcedOriginalClose = Stop-DesktopProcesses `
            -ExactPath $desktopExePath `
            -GraceSeconds $GracefulCloseSeconds
    }

    $launchStartedAtUtc = [DateTime]::UtcNow
    $testDesktopProcess = Start-DesktopSession `
        -Executable $desktopExePath `
        -SessionUrl $targetUrl
    $testDesktopReady = Wait-DesktopTargetReady `
        -RouteLog $routeLog `
        -ProcessId $testDesktopProcess.Id `
        -RoutingFingerprint $script:SafeRoutingFingerprint `
        -NotBeforeUtc $launchStartedAtUtc `
        -WaitSeconds $StartupTimeoutSeconds

    $preferencesAfterLaunch = Read-JsonObjectSafe `
        -Path $bindingPath `
        -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'
    $bindingAfterLaunch = Get-BindingEntry `
        -Preferences $preferencesAfterLaunch `
        -BindingId $targetBindingId `
        -RouteConfig $routeConfig
    if ($null -eq $bindingAfterLaunch) {
        Stop-LiveTest -Code 'TARGET_BINDING_LOST_ON_LAUNCH'
    }
    $bindingBeforeReconnect = Get-BindingInvariant -Binding $bindingAfterLaunch

    $uiDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $uiPromptUtc = [DateTime]::UtcNow
    $expectedRecoveryCauses = if ($RecoveryTrigger -eq 'RenderProcessExit') {
        @('RenderProcessExited')
    }
    else {
        @('UserRefresh', 'UserReconnect')
    }
    Write-LiveSafeEvent -Phase 'await-reconnect-ui' -Fields ([ordered]@{
        ok              = $true
        action          = if ($RecoveryTrigger -eq 'RenderProcessExit') {
            'terminate-pi-webview-renderer'
        }
        else {
            'focus-pi-web-desktop-and-press-ctrl-r'
        }
        routingFp       = $script:SafeRoutingFingerprint
        notificationFp  = $script:SafeNotificationFingerprint
        deadlineSeconds = $TimeoutSeconds
    })
    if ($RecoveryTrigger -eq 'RenderProcessExit') {
        Invoke-DesktopRendererFailure -DesktopProcessId $testDesktopProcess.Id
    }

    $issuedEvent = $null
    $injectionEvent = $null
    while ([DateTime]::UtcNow -lt $uiDeadlineUtc -and $null -eq $injectionEvent) {
        if ($null -eq (Get-Process -Id $testDesktopProcess.Id -ErrorAction SilentlyContinue)) {
            Stop-LiveTest -Code 'DESKTOP_EXITED_BEFORE_RECONNECT'
        }
        $newEvents = @(Get-RouteEvents -Path $routeLog -Tail 1800 | Where-Object {
            [int]$_.processId -eq $testDesktopProcess.Id -and
            [string]$_.runId -eq [string]$testDesktopReady.RunId -and
            (ConvertTo-EventUtc -EventRecord $_) -ge $uiPromptUtc
        })
        if ($null -eq $issuedEvent) {
            $issuedEvent = @($newEvents | Where-Object {
                [string]$_.eventName -eq 'route-document-recovery-issued' -and
                [string]$_.fields.cause -in $expectedRecoveryCauses
            } | Select-Object -First 1)
            if ($issuedEvent.Count -eq 1) {
                $issuedEvent = $issuedEvent[0]
                $recoveryIssuedAtUtc = ConvertTo-EventUtc -EventRecord $issuedEvent
            }
            else {
                $issuedEvent = $null
            }
        }
        if ($null -ne $issuedEvent) {
            $targetUnregistered = @($newEvents | Where-Object {
                (ConvertTo-EventUtc -EventRecord $_) -ge $recoveryIssuedAtUtc -and
                [string]$_.eventName -eq 'owner-unregistered' -and
                [string]$_.fields.routingFp -eq $script:SafeRoutingFingerprint
            } | Select-Object -First 1)
            if ($targetUnregistered.Count -eq 1) {
                $injectionEvent = $targetUnregistered[0]
            }
            else {
                $revoked = @($newEvents | Where-Object {
                    (ConvertTo-EventUtc -EventRecord $_) -ge $recoveryIssuedAtUtc -and
                    [string]$_.eventName -eq 'route-document-recovery-revoked'
                } | Select-Object -First 1)
                if ($revoked.Count -eq 1) {
                    $injectionEvent = $revoked[0]
                }
            }
        }
        if ($null -eq $injectionEvent) {
            Start-Sleep -Milliseconds 15
        }
    }
    if ($null -eq $issuedEvent) {
        Stop-LiveTest -Code 'RECONNECT_UI_NOT_OBSERVED'
    }
    if ($null -eq $injectionEvent) {
        Stop-LiveTest -Code 'OWNER_REVOCATION_NOT_OBSERVED'
    }

    $injectionEventName = [string]$injectionEvent.eventName
    $notificationPostedAtUtc = [DateTime]::UtcNow
    Invoke-LiveNotification `
        -Port $listenerPort `
        -Token $notifyToken `
        -NotificationId $notificationId `
        -NotificationFingerprint $script:SafeNotificationFingerprint `
        -InstanceKey $instanceKey `
        -RoutingKey $targetRoutingKey `
        -RequestTimeoutSeconds ([Math]::Min(180, $TimeoutSeconds + 30))

    Write-LiveSafeEvent -Phase 'notification-injected' -Fields ([ordered]@{
        ok              = $true
        routingFp       = $script:SafeRoutingFingerprint
        notificationFp  = $script:SafeNotificationFingerprint
        injectionEvent  = $injectionEventName
    })

    $popupDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $popupDeadlineUtc -and [string]::IsNullOrWhiteSpace($popupId)) {
        $listenerLines = @(Get-CorrelatedLogLines `
            -Path $listenerLog `
            -Needle ('notificationFp=' + $script:SafeNotificationFingerprint))
        if (@($listenerLines | Where-Object { $_ -match 'route-freeze-fail-closed' }).Count -gt 0) {
            Stop-LiveTest -Code 'CORRELATED_FAIL_CLOSED'
        }

        $brokerLines = @(Get-CorrelatedLogLines `
            -Path $brokerLog `
            -Needle ('notificationFp=' + $script:SafeNotificationFingerprint))
        $queueLine = @($brokerLines | Where-Object {
            $_ -match 'broker-popup-queue-dequeue\s+popupId=([^\s]+)'
        } | Select-Object -First 1)
        if ($queueLine.Count -eq 1 -and
            [string]$queueLine[0] -match 'broker-popup-queue-dequeue\s+popupId=([^\s]+)') {
            $popupId = [string]$Matches[1]
            $popupQueueMarker = [string]$queueLine[0]
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if ([string]::IsNullOrWhiteSpace($popupId)) {
        Stop-LiveTest -Code 'POPUP_NOT_OBSERVED'
    }

    $popupWindowDeadlineUtc = [DateTime]::UtcNow.AddSeconds(8)
    $popupWindowReady = $false
    while ([DateTime]::UtcNow -lt $popupWindowDeadlineUtc -and -not $popupWindowReady) {
        $popupWindowReady = @(Get-LogLinesAfterMarker `
            -Path $brokerLog `
            -Marker $popupQueueMarker |
            Where-Object {
                $_ -match ('broker-popup-start\s+popupId=' + [Regex]::Escape($popupId) + '(\s|$)')
            }).Count -eq 1
        if (-not $popupWindowReady) {
            Start-Sleep -Milliseconds 50
        }
    }
    if (-not $popupWindowReady) {
        Stop-LiveTest -Code 'POPUP_WINDOW_NOT_READY'
    }

    # A direct exact-ready freeze does not exercise the reconnect gap. Require
    # the listener itself to prove that this notification created a recovery
    # ticket before allowing the popup to be clicked.
    $listenerRecoveryLines = @(Get-CorrelatedLogLines `
        -Path $listenerLog `
        -Needle ('notificationFp=' + $script:SafeNotificationFingerprint))
    $freezeRecoveringLines = @($listenerRecoveryLines | Where-Object {
        $_ -match 'route-freeze\s+decision=exact-recovering\s+result=recovering\b'
    })
    $recoveryTicketLines = @($listenerRecoveryLines | Where-Object {
        $_ -match 'route-freeze-recovering\s+notificationFp=[0-9a-f]{16}\s+ticketFp=[0-9a-f]{16}\b'
    })
    if ($freezeRecoveringLines.Count -ne 1 -or
        $recoveryTicketLines.Count -ne 1) {
        Stop-LiveTest -Code 'RECOVERY_TICKET_NOT_OBSERVED'
    }
    $pendingRecoveryObserved = $true

    Write-LiveSafeEvent -Phase 'await-popup-click' -Fields ([ordered]@{
        ok              = $true
        action          = if ($ActivatePopupById) {
            'activate-the-exact-test-popup-through-broker'
        }
        else {
            'click-the-visible-test-notification-card'
        }
        routingFp       = $script:SafeRoutingFingerprint
        notificationFp  = $script:SafeNotificationFingerprint
        deadlineSeconds = $TimeoutSeconds
    })
    if ($ActivatePopupById -and
        -not (Close-TestPopupSafe `
            -BrokerPort $brokerPort `
            -PopupId $popupId `
            -Activate $true)) {
        Stop-LiveTest -Code 'POPUP_BROKER_ACTIVATION_FAILED'
    }

    $activationDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $activationSucceeded = $false
    while ([DateTime]::UtcNow -lt $activationDeadlineUtc -and -not $activationSucceeded) {
        $brokerPopupLines = @(Get-LogLinesAfterMarker `
            -Path $brokerLog `
            -Marker $popupQueueMarker |
            Where-Object {
                $_ -match ('\bpopupId=' + [Regex]::Escape($popupId) + '(\s|$)')
            })
        $popupClickLines = @(if ($ActivatePopupById) {
            $brokerPopupLines | Where-Object {
                $_ -match 'broker-close-by-id\s+popupId=[^\s]+\s+activate=True\b'
            }
        }
        else {
            $brokerPopupLines | Where-Object {
                $_ -match 'broker-popup-click\s+popupId='
            }
        })
        $popupClicked = $popupClickLines.Count -eq 1
        $activateActions = @(if ($ActivatePopupById) {
            $brokerPopupLines | Where-Object {
                $_ -match 'broker-close-by-id\s+popupId=[^\s]+\s+activate=True\b'
            }
        }
        else {
            $brokerPopupLines | Where-Object {
                $_ -match 'broker-action\s+activate\s+popupId='
            }
        })
        $resolveReady = @($brokerPopupLines | Where-Object {
            $_ -match 'broker-exact-worker-complete\s+popupId=[^\s]+\s+mode=resolve\s+decision=exact-ready\s+result=ready\b'
        })
        $handled = @($brokerPopupLines | Where-Object {
            $_ -match 'broker-exact-worker-complete\s+popupId=[^\s]+\s+mode=activate\s+decision=handled\s+result=session-url-confirmed\b'
        })
        if ($popupClickLines.Count -gt 1 -or
            $activateActions.Count -gt 1 -or
            $handled.Count -gt 1) {
            Stop-LiveTest -Code 'CORRELATED_ACTIVATION_DUPLICATED'
        }
        if (@($brokerPopupLines | Where-Object {
            $_ -match 'broker-popup-click-ignored|fail-closed|owner-unresolved|missing-snapshot|\bresult=(stale|ambiguous|timeout|expired|rejected)\b'
        }).Count -gt 0) {
            Stop-LiveTest -Code 'CORRELATED_ACTIVATION_FAILED'
        }

        $desktopEvents = @(Get-RouteEvents -Path $routeLog -Tail 3000 | Where-Object {
            [int]$_.processId -eq $testDesktopProcess.Id -and
            [string]$_.runId -eq [string]$testDesktopReady.RunId
        })
        $readyEvents = @($desktopEvents | Where-Object {
            [string]$_.eventName -eq 'poll-activation-ready' -and
            [string]$_.fields.notificationFp -eq $script:SafeNotificationFingerprint -and
            [string]$_.fields.routingFp -eq $script:SafeRoutingFingerprint
        })
        $confirmedEvents = @($desktopEvents | Where-Object {
            [string]$_.eventName -eq 'activate-confirmed' -and
            [string]$_.fields.notificationFp -eq $script:SafeNotificationFingerprint -and
            [string]$_.fields.routingFp -eq $script:SafeRoutingFingerprint -and
            [string]$_.fields.result -eq 'session-url-confirmed'
        })
        $acknowledgedEvents = @($desktopEvents | Where-Object {
            [string]$_.eventName -eq 'activate-result-acknowledged' -and
            [string]$_.fields.notificationFp -eq $script:SafeNotificationFingerprint -and
            [string]$_.fields.result -eq 'session-url-confirmed'
        })
        $completeEvents = @($desktopEvents | Where-Object {
            [string]$_.eventName -eq 'poll-activate-complete' -and
            [string]$_.fields.notificationFp -eq $script:SafeNotificationFingerprint -and
            [string]$_.fields.result -eq 'session-url-confirmed'
        })
        $uiStartEvents = @($desktopEvents | Where-Object {
            [string]$_.eventName -eq 'route-activation-ui-start' -and
            [string]$_.fields.routingFp -eq $script:SafeRoutingFingerprint -and
            (ConvertTo-EventUtc -EventRecord $_) -ge $notificationPostedAtUtc
        })

        $desktopCounts = [ordered]@{
            pollReady          = $readyEvents.Count
            uiStart            = $uiStartEvents.Count
            confirmed          = $confirmedEvents.Count
            resultAcknowledged = $acknowledgedEvents.Count
            pollComplete       = $completeEvents.Count
        }
        $brokerCounts = [ordered]@{
            popupClick = $popupClickLines.Count
            action     = $activateActions.Count
            resolveReady = $resolveReady.Count
            handled    = $handled.Count
        }
        $activationSucceeded = $popupClicked -and
            $activateActions.Count -eq 1 -and
            $handled.Count -eq 1 -and
            $readyEvents.Count -eq 1 -and
            $uiStartEvents.Count -eq 1 -and
            $confirmedEvents.Count -eq 1 -and
            $acknowledgedEvents.Count -eq 1 -and
            $completeEvents.Count -eq 1
        if (-not $activationSucceeded) {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $activationSucceeded) {
        Stop-LiveTest -Code 'ACTIVATION_SUCCESS_NOT_OBSERVED'
    }

    $allRecoveryEvents = @(Get-RouteEvents -Path $routeLog -Tail 3000 | Where-Object {
        [int]$_.processId -eq $testDesktopProcess.Id -and
        [string]$_.runId -eq [string]$testDesktopReady.RunId -and
        (ConvertTo-EventUtc -EventRecord $_) -ge $recoveryIssuedAtUtc
    })
    $restoredEvents = @($allRecoveryEvents | Where-Object {
        [string]$_.eventName -eq 'route-document-recovery-restored' -and
        [string]$_.fields.targetRoutingFp -eq $script:SafeRoutingFingerprint
    })
    if ($restoredEvents.Count -ne 1) {
        Stop-LiveTest -Code 'RECOVERY_RESTORE_COUNT_INVALID'
    }
    $recoveryRestoredAtUtc = ConvertTo-EventUtc -EventRecord $restoredEvents[0]
    $injectedBeforeRestore = $notificationPostedAtUtc -le $recoveryRestoredAtUtc

    $restoredOwners = @($allRecoveryEvents | Where-Object {
        [string]$_.eventName -eq 'owner-registered' -and
        [string]$_.fields.routingFp -eq $script:SafeRoutingFingerprint
    })
    if ($restoredOwners.Count -lt 1) {
        Stop-LiveTest -Code 'RECOVERY_OWNER_NOT_RESTORED'
    }
    $restoredOwner = $restoredOwners[-1]
    $ownerIdentityRotated =
        [string]$restoredOwner.fields.ownerFp -ne [string]$testDesktopReady.OwnerFp -or
        [string]$restoredOwner.fields.pageFp -ne [string]$testDesktopReady.PageFp
    if (-not $ownerIdentityRotated) {
        Stop-LiveTest -Code 'RECOVERY_OWNER_IDENTITY_REUSED'
    }

    $listenerLines = @(Get-CorrelatedLogLines `
        -Path $listenerLog `
        -Needle ('notificationFp=' + $script:SafeNotificationFingerprint))
    $notifyReceived = @($listenerLines | Where-Object {
        $_ -match 'notify-received\s+originKind=pi-web' -and
        $_ -match ('routingFp=' + [Regex]::Escape($script:SafeRoutingFingerprint))
    }).Count
    $pendingRecoveryObserved = @($listenerLines | Where-Object {
        $_ -match 'route-freeze\s+decision=exact-recovering\s+result=recovering\b'
    }).Count -eq 1 -and @($listenerLines | Where-Object {
        $_ -match 'route-freeze-recovering\s+notificationFp=[0-9a-f]{16}\s+ticketFp=[0-9a-f]{16}\b'
    }).Count -eq 1
    if ($notifyReceived -ne 1 -or
        -not $pendingRecoveryObserved -or
        @($listenerLines | Where-Object { $_ -match 'route-freeze-fail-closed' }).Count -gt 0) {
        Stop-LiveTest -Code 'LISTENER_CORRELATION_INVALID'
    }

    $preferencesAfterReconnect = Read-JsonObjectSafe `
        -Path $bindingPath `
        -FailureCode 'ROUTE_BINDINGS_UNAVAILABLE'
    $bindingAfterReconnect = Get-BindingEntry `
        -Preferences $preferencesAfterReconnect `
        -BindingId $targetBindingId `
        -RouteConfig $routeConfig
    if ($null -eq $bindingAfterReconnect) {
        Stop-LiveTest -Code 'TARGET_BINDING_LOST_AFTER_RECONNECT'
    }
    $bindingUnchanged = Test-BindingInvariantEqual `
        -Before $bindingBeforeReconnect `
        -After (Get-BindingInvariant -Binding $bindingAfterReconnect)
    if (-not $bindingUnchanged) {
        Stop-LiveTest -Code 'FIRST_OPEN_BINDING_MUTATED'
    }

    $success = $true
    $script:FailureCode = 'PASS'
}
catch {
    # Deliberately suppress the exception text. It can contain a configured URL,
    # token, session identity, request body, or process arguments.
    $exceptionType = $_.Exception.GetType().Name
    $scriptLine = [int]$_.InvocationInfo.ScriptLineNumber
    $script:FailureDetail = ('{0}:line-{1}' -f $exceptionType, $scriptLine)
}
finally {
    $failureBeforeCleanup = $script:FailureCode
    if (-not $success -and -not $popupClicked -and
        -not [string]::IsNullOrWhiteSpace($popupId)) {
        $popupClosedDuringCleanup = Close-TestPopupSafe `
            -BrokerPort $brokerPort `
            -PopupId $popupId
    }

    if (-not [string]::IsNullOrWhiteSpace($desktopExePath)) {
        try {
            if ($originalWasRunning) {
                $running = @(Get-DesktopProcesses -ExactPath $desktopExePath)
                $alreadyRestored = $false
                if ($running.Count -eq 1 -and
                    -not [string]::IsNullOrWhiteSpace($script:SafeRoutingFingerprint) -and
                    -not [string]::IsNullOrWhiteSpace($routeLog)) {
                    $current = Get-LatestCurrentRouteEvent `
                        -RouteLog $routeLog `
                        -ProcessIds @([int]$running[0].Id) `
                        -ExpectedRoutingFingerprint $script:SafeRoutingFingerprint
                    $alreadyRestored = $null -ne $current
                }
                if ($alreadyRestored) {
                    $processRestored = $true
                }
                elseif (-not [string]::IsNullOrWhiteSpace($targetUrl)) {
                    [void](Stop-DesktopProcesses `
                        -ExactPath $desktopExePath `
                        -GraceSeconds $GracefulCloseSeconds)
                    $restoreStartedAtUtc = [DateTime]::UtcNow
                    $restoredProcess = Start-DesktopSession `
                        -Executable $desktopExePath `
                        -SessionUrl $targetUrl
                    $null = Wait-DesktopTargetReady `
                        -RouteLog $routeLog `
                        -ProcessId $restoredProcess.Id `
                        -RoutingFingerprint $script:SafeRoutingFingerprint `
                        -NotBeforeUtc $restoreStartedAtUtc `
                        -WaitSeconds $StartupTimeoutSeconds
                    $processRestored = $true
                }
            }
            else {
                if (@(Get-DesktopProcesses -ExactPath $desktopExePath).Count -gt 0) {
                    [void](Stop-DesktopProcesses `
                        -ExactPath $desktopExePath `
                        -GraceSeconds $GracefulCloseSeconds)
                }
                $processRestored = @(Get-DesktopProcesses -ExactPath $desktopExePath).Count -eq 0
            }
        }
        catch {
            $processRestored = $false
            if ($success) {
                $success = $false
                $script:FailureCode = 'PROCESS_RESTORE_FAILED'
            }
            else {
                $script:FailureCode = $failureBeforeCleanup
            }
        }
    }
}

$durationMs = [int][Math]::Max(0, ([DateTime]::UtcNow - $startedAtUtc).TotalMilliseconds)
if ($success) {
    Write-LiveSafeEvent -Phase 'complete' -Fields ([ordered]@{
        ok                         = $true
        code                       = 'PASS'
        routingFp                  = $script:SafeRoutingFingerprint
        notificationFp             = $script:SafeNotificationFingerprint
        injectionEvent             = $injectionEventName
        injectedBeforeRestore      = $injectedBeforeRestore
        pendingRecoveryObserved    = $pendingRecoveryObserved
        popupClicked               = $popupClicked
        activationInput            = if ($ActivatePopupById) { 'broker-exact' } else { 'ui-click' }
        bindingUnchanged           = $bindingUnchanged
        ownerIdentityRotated       = $ownerIdentityRotated
        activationConfirmed        = $true
        desktopCounts              = $desktopCounts
        brokerCounts               = $brokerCounts
        originalCloseWasForced     = $forcedOriginalClose
        originalProcessStateRestored = $processRestored
        durationMs                 = $durationMs
    })
    exit 0
}

Write-LiveSafeEvent -Phase 'failed' -Fields ([ordered]@{
    ok                           = $false
    code                         = $script:FailureCode
    failureDetail                = $script:FailureDetail
    routingFp                    = $script:SafeRoutingFingerprint
    notificationFp               = $script:SafeNotificationFingerprint
    injectionEvent               = $injectionEventName
        popupClicked                 = $popupClicked
        activationInput              = if ($ActivatePopupById) { 'broker-exact' } else { 'ui-click' }
    testPopupClosed              = $popupClosedDuringCleanup
    originalProcessStateRestored = $processRestored
    durationMs                   = $durationMs
})
exit 1
