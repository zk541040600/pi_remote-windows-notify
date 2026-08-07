[CmdletBinding()]
param(
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$ConfigPath,
    [string]$AppId = "Pi Remote",
    [switch]$Once,
    [string]$TestDesktopSinkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Security

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('ListenHost')) { $configArgs.ListenHost = $ListenHost }
if ($PSBoundParameters.ContainsKey('Port')) { $configArgs.Port = $Port }
if ($PSBoundParameters.ContainsKey('Token')) { $configArgs.Token = $Token }
$config = Ensure-NotifyBridgeConfig @configArgs
$ListenHost = $config.ListenHost
$Port = $config.Port
$Token = $config.Token
$ConfigPath = $config.ConfigPath
$DisplayMode = $config.DisplayMode
$PopupTimeoutSeconds = $config.PopupTimeoutSeconds
$script:NotifyToastEventHandlers = New-Object System.Collections.ArrayList
$script:NotifyActivationCleanupTimers = New-Object System.Collections.ArrayList
$script:NotifyToastRecoveryWorkers = New-Object System.Collections.ArrayList
$script:NotifyActivationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
$script:NotifyPopupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
$script:NotifyBrokerScript = Join-Path $PSScriptRoot 'pi-notify-broker.ps1'
$script:NotifyPowerShellExe = Get-NotifyBridgePowerShellExe
$script:NotifyListenerLogPath = Join-Path (Get-NotifyBridgeLogDir) 'listener.log'
$script:NotifyRecentNotifications = @()
$script:NotifyQqWorkers = New-Object System.Collections.ArrayList
$script:NotifyQqWorkerScript = Join-Path $PSScriptRoot 'pi-notify-qq-sender.ps1'
$script:NotifyQqPendingDir = Join-Path (Get-NotifyBridgeBaseDir) 'qq-pending'
$script:NotifyQqEnabled = [bool]$config.QqNotifyEnabled
$script:NotifyQqSenderScript = [string]$config.QqSenderScript
$script:NotifyQqMaxConcurrent = [Math]::Max(1, [Math]::Min(8, [int]$config.QqMaxConcurrent))
$script:NotifyQqTimeoutSeconds = [Math]::Max(1, [Math]::Min(120, [int]$config.QqSendTimeoutSeconds))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyListenerLogPath) | Out-Null
Clear-NotifyBridgePopupArtifacts -MaxAgeMinutes 10

function Write-NotifyListenerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyListenerLogPath -Value $line -Encoding UTF8
}

# Normalize one display field before it crosses into the QQ sender boundary.
function ConvertTo-NotifyQqTextPart {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [int]$MaxLength
    )

    $normalized = [regex]::Replace([string]$Value, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\s]+', ' ').Trim()
    if ($normalized.Length -le $MaxLength) {
        return $normalized
    }
    return $normalized.Substring(0, $MaxLength).TrimEnd()
}

# Prepare the instance-local private pending directory and remove abandoned message files.
function Initialize-NotifyQqPendingDirectory {
    if (-not (Test-Path -LiteralPath $script:NotifyQqPendingDir)) {
        if (-not $script:NotifyQqEnabled) {
            return $true
        }
        New-Item -ItemType Directory -Force -Path $script:NotifyQqPendingDir | Out-Null
    }

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
        [System.IO.Directory]::SetAccessControl($script:NotifyQqPendingDir, $security)
    }
    catch {
        Write-NotifyListenerLog -Message ('qq-pending-unavailable reason={0}' -f $_.Exception.GetType().Name)
        return $false
    }

    $cutoff = (Get-Date).AddMinutes(-[Math]::Max(10, [Math]::Ceiling($script:NotifyQqTimeoutSeconds * 3 / 60)))
    $removed = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $script:NotifyQqPendingDir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
        if ($item.LastWriteTime -ge $cutoff) {
            continue
        }
        try {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            $removed += 1
        }
        catch {
            Write-NotifyListenerLog -Message ('qq-pending-cleanup-failed reason={0}' -f $_.Exception.GetType().Name)
        }
    }
    if ($removed -gt 0) {
        Write-NotifyListenerLog -Message ('qq-pending-cleaned count={0}' -f $removed)
    }
    return $true
}

# Drop completed process handles before enforcing the listener-local worker limit.
function Clear-NotifyQqCompletedWorkers {
    for ($index = $script:NotifyQqWorkers.Count - 1; $index -ge 0; $index--) {
        $worker = $script:NotifyQqWorkers[$index]
        $remove = $false
        try { $remove = $worker.HasExited } catch { $remove = $true }
        if (-not $remove) {
            continue
        }
        try { $worker.Dispose() } catch {}
        $script:NotifyQqWorkers.RemoveAt($index)
    }
}

# Launch one bounded best-effort QQ worker without exposing notification content on the command line.
function Start-NotifyQqDispatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    if (-not $script:NotifyQqEnabled) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:NotifyQqWorkerScript -PathType Leaf)) {
        Write-NotifyListenerLog -Message 'qq-send-unavailable reason=worker'
        return
    }
    if ([string]::IsNullOrWhiteSpace($script:NotifyQqSenderScript) -or -not (Test-Path -LiteralPath $script:NotifyQqSenderScript -PathType Leaf)) {
        Write-NotifyListenerLog -Message 'qq-send-unavailable reason=sender'
        return
    }
    if (-not (Test-Path -LiteralPath $script:NotifyQqPendingDir -PathType Container)) {
        Write-NotifyListenerLog -Message 'qq-send-unavailable reason=pending-directory'
        return
    }

    Clear-NotifyQqCompletedWorkers
    if ($script:NotifyQqWorkers.Count -ge $script:NotifyQqMaxConcurrent) {
        Write-NotifyListenerLog -Message ('qq-send-drop reason=capacity active={0} limit={1}' -f $script:NotifyQqWorkers.Count, $script:NotifyQqMaxConcurrent)
        return
    }

    $textFile = Join-Path $script:NotifyQqPendingDir ('qq-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
    try {
        $qqTitle = ConvertTo-NotifyQqTextPart -Value $Title -MaxLength 80
        $qqBody = ConvertTo-NotifyQqTextPart -Value $Body -MaxLength 220
        $qqText = if ([string]::IsNullOrWhiteSpace($qqBody)) { $qqTitle } else { $qqTitle + [System.Environment]::NewLine + $qqBody }
        [System.IO.File]::WriteAllText($textFile, $qqText, [System.Text.UTF8Encoding]::new($false))

        $workerArgs = Join-NotifyBridgeProcessArguments @(
            '-NoProfile',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script:NotifyQqWorkerScript,
            '-ConfigPath', $ConfigPath,
            '-TextFile', $textFile
        )
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:NotifyPowerShellExe
        $startInfo.Arguments = $workerArgs
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $worker = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $worker) {
            throw 'QQ worker process did not start.'
        }
        [void]$script:NotifyQqWorkers.Add($worker)
        Write-NotifyListenerLog -Message ('qq-send-started active={0} limit={1}' -f $script:NotifyQqWorkers.Count, $script:NotifyQqMaxConcurrent)
    }
    catch {
        Remove-Item -LiteralPath $textFile -Force -ErrorAction SilentlyContinue
        Write-NotifyListenerLog -Message ('qq-send-error reason={0}' -f $_.Exception.GetType().Name)
    }
}

$qqPendingReady = Initialize-NotifyQqPendingDirectory
if ($script:NotifyQqEnabled) {
    Write-NotifyListenerLog -Message ('qq-notify-start enabled=True ready={0} limit={1} timeoutSeconds={2}' -f $qqPendingReady, $script:NotifyQqMaxConcurrent, $script:NotifyQqTimeoutSeconds)
}
else {
    Write-NotifyListenerLog -Message 'qq-notify-start enabled=False'
}

function Start-NotifyRouteHostDaemon {
    try {
        $routeHostExe = Get-NotifyRouteHostExe -Config $config
        if ([string]::IsNullOrWhiteSpace($routeHostExe) -or -not (Test-Path -LiteralPath $routeHostExe)) {
            Write-NotifyListenerLog -Message 'route-host-start-skip missing-executable'
            return
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $routeHostExe
        $startInfo.Arguments = '--daemon'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $routeProcess = [System.Diagnostics.Process]::Start($startInfo)
        Write-NotifyListenerLog -Message ('route-host-start-request pid={0}' -f $routeProcess.Id)
    }
    catch {
        Write-NotifyListenerLog -Message ('route-host-start-error reason={0}' -f $_.Exception.GetType().Name)
    }
}

Start-NotifyRouteHostDaemon

function Write-HttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [string]$Body = "",
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $header = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Test-NotifyListenerClientDisconnect {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if (($current -is [System.IO.IOException]) -or ($current -is [System.Net.Sockets.SocketException])) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Read-HttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream
    )

    $maxBodyBytes = 65536
    $buffer = [byte[]]::new(4096)
    $memory = [System.IO.MemoryStream]::new()
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        $memory.Write($buffer, 0, $read)
        $bytes = $memory.ToArray()
        $startIndex = [Math]::Max(0, $bytes.Length - $read - 3)
        for ($i = $startIndex; $i -le $bytes.Length - 4; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) {
                $headerEnd = $i + 4
                break
            }
        }

        if ($memory.Length -gt 65536) {
            throw "HTTP header too large."
        }
    }

    if ($headerEnd -lt 0) {
        throw "Incomplete HTTP request header."
    }

    $allBytes = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = if ($lines.Length -gt 0) { [string]$lines[0] } else { '' }
    $requestLine = $requestLine.Trim()
    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        throw "Missing HTTP request line."
    }

    $headers = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($lines.Length -gt 1) {
        foreach ($line in $lines[1..($lines.Length - 1)]) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $index = $line.IndexOf(':')
            if ($index -le 0) {
                continue
            }
            $headers[$line.Substring(0, $index).Trim()] = $line.Substring($index + 1).Trim()
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        [int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength) | Out-Null
    }
    if ($contentLength -lt 0) {
        throw "Invalid HTTP content length."
    }
    if ($contentLength -gt $maxBodyBytes) {
        throw "HTTP request body too large."
    }

    $bodyMemory = [System.IO.MemoryStream]::new()
    $existingBytes = $allBytes.Length - $headerEnd
    if ($existingBytes -gt $maxBodyBytes) {
        throw "HTTP request body too large."
    }
    if ($existingBytes -gt 0) {
        $bodyMemory.Write($allBytes, $headerEnd, $existingBytes)
    }

    while ($bodyMemory.Length -lt $contentLength) {
        $remaining = [Math]::Min($buffer.Length, $contentLength - [int]$bodyMemory.Length)
        $read = $Stream.Read($buffer, 0, $remaining)
        if ($read -le 0) {
            break
        }
        $bodyMemory.Write($buffer, 0, $read)
    }

    $bodyBytes = $bodyMemory.ToArray()
    if ($bodyBytes.Length -gt $contentLength) {
        $trimmed = [byte[]]::new($contentLength)
        [Array]::Copy($bodyBytes, 0, $trimmed, 0, $contentLength)
        $bodyBytes = $trimmed
    }

    return [pscustomobject]@{
        RequestLine = $requestLine
        Headers     = $headers
        BodyBytes   = $bodyBytes
    }
}

function Get-NotifyBridgeActivationUri {
    param([string]$ActivationId)

    $protocol = Get-NotifyBridgeProtocolName
    if (-not [string]::IsNullOrWhiteSpace($ActivationId)) {
        return ('{0}://focus?id={1}' -f $protocol, [Uri]::EscapeDataString($ActivationId.Trim()))
    }
    return ('{0}://focus' -f $protocol)
}

function Get-NotifyPopupTargetKey {
    param(
        [string]$TargetHost,
        [string]$CwdBase,
        [string]$TabTitle
    )

    $hostPart = if ([string]::IsNullOrWhiteSpace($TargetHost)) { '' } else { $TargetHost.Trim().ToLowerInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($TabTitle)) {
        return ('tab:{0}|{1}' -f $hostPart, $TabTitle.Trim().ToLowerInvariant())
    }
    if (-not [string]::IsNullOrWhiteSpace($CwdBase)) {
        return ('cwd:{0}|{1}' -f $hostPart, $CwdBase.Trim().ToLowerInvariant())
    }
    return ('host:{0}' -f $hostPart)
}

function Get-NotifyPopupTargetFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetKey
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($TargetKey))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Protect-NotifyActivationValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Save-NotifyToastActivationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActivationId,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [int]$TtlSeconds = 600
    )

    try {
        $ttl = [Math]::Max(3, [Math]::Min(1800, $TtlSeconds))
        $logDirs = @((Get-NotifyBridgeLogDir), (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs')) | Select-Object -Unique
        $payload = @{
            activationId   = $ActivationId
            protectedHost  = Protect-NotifyActivationValue -Value $FocusTarget
            protectedCwd   = Protect-NotifyActivationValue -Value $CwdBase
            protectedTab   = Protect-NotifyActivationValue -Value $TabTitle
            expiresAtTicks = [DateTime]::UtcNow.AddSeconds($ttl).Ticks
        }
        # Exact-route handles only: never store raw session/instance/routing keys.
        if (-not [string]::IsNullOrWhiteSpace($OriginKind)) {
            $payload['originKind'] = $OriginKind
        }
        if (-not [string]::IsNullOrWhiteSpace($NotificationId)) {
            $payload['protectedNotificationId'] = Protect-NotifyActivationValue -Value $NotificationId
        }
        if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) {
            $payload['protectedSnapshotId'] = Protect-NotifyActivationValue -Value $SnapshotId
        }
        if (-not [string]::IsNullOrWhiteSpace($RecoveryTicketId)) {
            $payload['protectedRecoveryTicketId'] = Protect-NotifyActivationValue -Value $RecoveryTicketId
        }
        $writtenPaths = @()
        foreach ($logDir in $logDirs) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue)) {
                $remove = $item.LastWriteTime -lt (Get-Date).AddMinutes(-30)
                if (-not $remove) {
                    try {
                        $existing = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                        $existingExpiry = [int64]0
                        if ($existing.PSObject.Properties['expiresAtTicks']) {
                            [void][int64]::TryParse([string]$existing.expiresAtTicks, [ref]$existingExpiry)
                        }
                        $remove = $existingExpiry -le [DateTime]::UtcNow.Ticks
                    }
                    catch { $remove = $true }
                }
                if ($remove) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
            }
            # Reserve one slot so toast pointer files stay bounded with the timer list.
            $remaining = @(Get-ChildItem -LiteralPath $logDir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            while ($remaining.Count -gt 95) {
                Remove-Item -LiteralPath $remaining[0].FullName -Force -ErrorAction SilentlyContinue
                $remaining = @($remaining | Select-Object -Skip 1)
            }
            $path = Join-Path $logDir ('activation-{0}.json' -f $ActivationId)
            [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
            $writtenPaths += $path
        }
        $cleanupTimer = [System.Threading.Timer]::new([System.Threading.TimerCallback]{
            param($state)
            foreach ($path in @($state)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {} }
        }, @($writtenPaths), [TimeSpan]::FromSeconds($ttl), [System.Threading.Timeout]::InfiniteTimeSpan)
        [void]$script:NotifyActivationCleanupTimers.Add($cleanupTimer)
        while ($script:NotifyActivationCleanupTimers.Count -gt 96) {
            try { $script:NotifyActivationCleanupTimers[0].Dispose() } catch {}
            $script:NotifyActivationCleanupTimers.RemoveAt(0)
        }
        return @($writtenPaths)
    }
    catch {
        Write-NotifyListenerLog -Message ('activation-cache-write-error reason={0}' -f $_.Exception.GetType().Name)
    }
}

# Harvest completed system-toast recovery workers. Recovery runs outside the
# listener request thread so a reconnect can never delay the HTTP response.
function Clear-NotifyToastRecoveryWorkers {
    for ($index = $script:NotifyToastRecoveryWorkers.Count - 1; $index -ge 0; $index--) {
        $worker = $script:NotifyToastRecoveryWorkers[$index]
        if (-not $worker.AsyncResult.IsCompleted) {
            continue
        }

        try {
            $result = @($worker.PowerShell.EndInvoke($worker.AsyncResult) | Select-Object -Last 1)
            if ($result.Count -gt 0) {
                $item = $result[0]
                Write-NotifyListenerLog -Message ('toast-recovery-complete decision={0} result={1} notificationFp={2} ticketFp={3} snapshotFp={4}' -f [string]$item.Decision, [string]$item.Result, (Get-NotifyRouteFingerprint -Value $worker.NotificationId), (Get-NotifyRouteFingerprint -Value $worker.RecoveryTicketId), (Get-NotifyRouteFingerprint -Value ([string]$item.SnapshotId)))
            }
        }
        catch {
            Write-NotifyListenerLog -Message ('toast-recovery-error reason={0} notificationFp={1} ticketFp={2}' -f $_.Exception.GetType().Name, (Get-NotifyRouteFingerprint -Value $worker.NotificationId), (Get-NotifyRouteFingerprint -Value $worker.RecoveryTicketId))
        }
        finally {
            try { $worker.PowerShell.Dispose() } catch {}
            try { $worker.Runspace.Close(); $worker.Runspace.Dispose() } catch {}
            $script:NotifyToastRecoveryWorkers.RemoveAt($index)
        }
    }
}

# Resolve a pre-snapshot recovery ticket as soon as its original owner returns,
# then atomically upgrade the protected activation cache. A click racing this
# write still carries the ticket and resolves through pi-notify-activate.ps1.
function Start-NotifyToastRecoveryWorker {
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$RecoveryTicketId,
        [Parameter(Mandatory = $true)][string[]]$ActivationPaths
    )

    if ($ActivationPaths.Count -eq 0) { return $false }
    Clear-NotifyToastRecoveryWorkers

    # Auto-resolution is best effort; click-time recovery remains authoritative.
    # Keep an accidental notification burst from creating unbounded runspaces.
    if ($script:NotifyToastRecoveryWorkers.Count -ge 32) {
        Write-NotifyListenerLog -Message ('toast-recovery-skip reason=capacity notificationFp={0} ticketFp={1}' -f (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $RecoveryTicketId))
        return $false
    }

    $workerScript = {
        param($commonPath, $configPath, $activationId, $notificationId, $recoveryTicketId, $activationPaths)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        . $commonPath
        Add-Type -AssemblyName System.Security

        $config = Ensure-NotifyBridgeConfig -ConfigPath $configPath
        $outcome = Wait-NotifyExactRouteRecovery -NotificationId $notificationId -RecoveryTicketId $recoveryTicketId -Config $config -WaitMs 125000
        $decision = [string]$outcome.Decision.Decision
        $result = [string]$outcome.Decision.Result
        $snapshotId = if ($decision -eq 'exact-ready') { [string]$outcome.Decision.SnapshotId } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($snapshotId)) {
            $snapshotBytes = [System.Text.Encoding]::UTF8.GetBytes($snapshotId)
            $protectedSnapshot = [Convert]::ToBase64String(
                [System.Security.Cryptography.ProtectedData]::Protect(
                    $snapshotBytes,
                    $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser))

            foreach ($path in @($activationPaths)) {
                $tempPath = ''
                try {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                    $payload = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                    if (-not $payload.PSObject.Properties['activationId'] -or [string]$payload.activationId -ne $activationId) { continue }
                    $payload | Add-Member -NotePropertyName protectedSnapshotId -NotePropertyValue $protectedSnapshot -Force
                    $tempPath = Join-Path (Split-Path -Parent $path) ('.activation-{0}-{1}.tmp' -f $activationId, [Guid]::NewGuid().ToString('N'))
                    [System.IO.File]::WriteAllText($tempPath, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
                    [System.IO.File]::Replace($tempPath, $path, [NullString]::Value)
                    $tempPath = ''
                }
                catch {
                    # A click can consume/delete the cache while recovery is
                    # completing. That race is safe because the click already
                    # loaded the same recovery ticket.
                }
                finally {
                    if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
                        try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            }
        }

        [pscustomobject]@{
            Decision = $decision
            Result = $result
            SnapshotId = $snapshotId
        }
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $powerShell = [System.Management.Automation.PowerShell]::Create()
    try {
        $runspace.Open()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript($workerScript.ToString())
        [void]$powerShell.AddArgument((Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'))
        [void]$powerShell.AddArgument($ConfigPath)
        [void]$powerShell.AddArgument($ActivationId)
        [void]$powerShell.AddArgument($NotificationId)
        [void]$powerShell.AddArgument($RecoveryTicketId)
        [void]$powerShell.AddArgument(@($ActivationPaths))
        $asyncResult = $powerShell.BeginInvoke()
        [void]$script:NotifyToastRecoveryWorkers.Add([pscustomobject]@{
            PowerShell = $powerShell
            Runspace = $runspace
            AsyncResult = $asyncResult
            NotificationId = $NotificationId
            RecoveryTicketId = $RecoveryTicketId
        })
        return $true
    }
    catch {
        try { $powerShell.Dispose() } catch {}
        try { $runspace.Close(); $runspace.Dispose() } catch {}
        Write-NotifyListenerLog -Message ('toast-recovery-start-error reason={0} notificationFp={1} ticketFp={2}' -f $_.Exception.GetType().Name, (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $RecoveryTicketId))
        return $false
    }
}

function Get-NotifyCommandLineArgument {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match($CommandLine, ('(?i)-{0}\s+"([^"]*)"' -f $escapedName))
    if ($match.Success) { return $match.Groups[1].Value }
    $match = [regex]::Match($CommandLine, ('(?i)-{0}\s+([^\s]+)' -f $escapedName))
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-NotifyPopupProcesses {
    $rows = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -like '*pi-notify-popup.ps1*' })
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            $popupConfigPath = Get-NotifyCommandLineArgument -CommandLine $commandLine -Name 'ConfigPath'
            if ([string]::IsNullOrWhiteSpace($popupConfigPath)) { continue }
            try {
                if (-not ([System.IO.Path]::GetFullPath($popupConfigPath).Equals([System.IO.Path]::GetFullPath($ConfigPath), [System.StringComparison]::OrdinalIgnoreCase))) { continue }
            }
            catch { continue }
            $targetFingerprint = Get-NotifyCommandLineArgument -CommandLine $commandLine -Name 'TargetFingerprint'
            $slot = -1
            [int]::TryParse((Get-NotifyCommandLineArgument -CommandLine $commandLine -Name 'StackIndex'), [ref]$slot) | Out-Null
            $rows += [pscustomobject]@{
                ProcessId         = [int]$process.ProcessId
                TargetFingerprint = $targetFingerprint
                StackIndex        = $slot
            }
        }
    }
    catch {
        Write-NotifyListenerLog -Message ('popup-process-scan-error "{0}"' -f $_.Exception.Message)
    }
    return @($rows)
}

function Get-NotifyPopupStackPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetKey,
        [string]$TargetFingerprint = ''
    )

    $targetFingerprint = if ([string]::IsNullOrWhiteSpace($TargetFingerprint)) {
        Get-NotifyPopupTargetFingerprint -TargetKey $TargetKey
    } else {
        $TargetFingerprint
    }
    $usedSlots = @{}
    $reuseSlot = -1
    foreach ($popup in Get-NotifyPopupProcesses) {
        $popupFingerprint = [string]$popup.TargetFingerprint
        $sameTarget = (-not [string]::IsNullOrWhiteSpace($popupFingerprint) -and $popupFingerprint -eq $targetFingerprint)
        $slot = [int]$popup.StackIndex

        if ($sameTarget) {
            if ($slot -ge 0 -and ($reuseSlot -lt 0 -or $slot -lt $reuseSlot)) { $reuseSlot = $slot }
            try {
                Stop-Process -Id $popup.ProcessId -Force -ErrorAction Stop
                Write-NotifyListenerLog -Message ('popup-replace-same-target pid={0} targetFingerprint="{1}" slot={2}' -f $popup.ProcessId, $targetFingerprint, $slot)
            }
            catch {
                Write-NotifyListenerLog -Message ('popup-replace-stop-error pid={0} targetFingerprint="{1}" "{2}"' -f $popup.ProcessId, $targetFingerprint, $_.Exception.Message)
            }
            continue
        }

        if ($slot -ge 0) { $usedSlots[[string]$slot] = $true }
    }

    if ($reuseSlot -ge 0 -and -not $usedSlots.ContainsKey([string]$reuseSlot)) { return $reuseSlot }
    for ($slot = 0; $slot -lt 64; $slot++) {
        if (-not $usedSlots.ContainsKey([string]$slot)) { return $slot }
    }
    return 63
}

function Stop-NotifyPopupTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetKey,
        [string]$Reason = 'dedupe'
    )

    $targetFingerprint = Get-NotifyPopupTargetFingerprint -TargetKey $TargetKey
    foreach ($popup in Get-NotifyPopupProcesses) {
        $popupFingerprint = [string]$popup.TargetFingerprint
        $sameTarget = (-not [string]::IsNullOrWhiteSpace($popupFingerprint) -and $popupFingerprint -eq $targetFingerprint)
        if (-not $sameTarget) { continue }
        try {
            Stop-Process -Id $popup.ProcessId -Force -ErrorAction Stop
            Write-NotifyListenerLog -Message ('popup-stop-target pid={0} targetFingerprint="{1}" reason={2}' -f $popup.ProcessId, $targetFingerprint, $Reason)
        }
        catch {
            Write-NotifyListenerLog -Message ('popup-stop-target-error pid={0} targetFingerprint="{1}" reason={2} "{3}"' -f $popup.ProcessId, $targetFingerprint, $Reason, $_.Exception.Message)
        }
    }
}

function Test-NotifyDuplicateDrop {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$OriginKind = '',
        [switch]$CheckOnly
    )

    $now = Get-Date
    $precise = -not [string]::IsNullOrWhiteSpace($CwdBase) -or -not [string]::IsNullOrWhiteSpace($TabTitle)
    $originPart = if ([string]::IsNullOrWhiteSpace($OriginKind)) { 'none' } else { $OriginKind.Trim().ToLowerInvariant() }
    $signature = ('{0}`n{1}`n{2}`n{3}' -f $originPart, ([string]$FocusTarget).Trim().ToLowerInvariant(), $Title.Trim(), $Body.Trim())
    $script:NotifyRecentNotifications = @($script:NotifyRecentNotifications | Where-Object { ($now - $_.Time).TotalSeconds -lt 5 })
    $matches = @($script:NotifyRecentNotifications | Where-Object { $_.Signature -eq $signature })

    if (-not $precise -and @($matches | Where-Object { $_.Precise }).Count -gt 0) {
        Write-NotifyListenerLog -Message ('notify-dedup drop-imprecise targetFingerprint="{0}"' -f (Get-NotifyPopupTargetFingerprint -TargetKey $FocusTarget))
        return $true
    }

    if ($precise -and @($matches | Where-Object { -not $_.Precise }).Count -gt 0) {
        $hostKey = Get-NotifyPopupTargetKey -TargetHost $FocusTarget -CwdBase '' -TabTitle ''
        Stop-NotifyPopupTarget -TargetKey $hostKey -Reason 'dedupe-precise-arrived'
    }

    if (-not $CheckOnly) {
        $script:NotifyRecentNotifications += [pscustomobject]@{
            Time      = $now
            Signature = $signature
            Precise   = $precise
        }
    }
    return $false
}

# Broker delegation helpers: prefer long-lived broker for popup-focus, fall back to per-popup process
function Test-NotifyBrokerHealth {
    try {
        $request = [System.Net.HttpWebRequest]::Create($config.BrokerHealthUrl)
        $request.Method = 'GET'
        $request.Timeout = [Math]::Max(100, [int]$config.BrokerRequestTimeoutMs)
        $request.ReadWriteTimeout = [Math]::Max(100, [int]$config.BrokerRequestTimeoutMs)
        $response = $request.GetResponse()
        try { return ([int]$response.StatusCode -eq 200) } finally { $response.Close() }
    }
    catch {
        return $false
    }
}

function Get-NotifyBrokerProcessIds {
    $processIds = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -like '*pi-notify-broker.ps1*' })
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            $brokerConfigPath = Get-NotifyCommandLineArgument -CommandLine $commandLine -Name 'ConfigPath'
            if ([string]::IsNullOrWhiteSpace($brokerConfigPath)) { continue }
            try {
                if (-not ([System.IO.Path]::GetFullPath($brokerConfigPath).Equals([System.IO.Path]::GetFullPath($ConfigPath), [System.StringComparison]::OrdinalIgnoreCase))) { continue }
            }
            catch { continue }
            $processIds += [int]$process.ProcessId
        }
    }
    catch {
        Write-NotifyListenerLog -Message ('broker-process-scan-error "{0}"' -f $_.Exception.Message)
    }
    return @($processIds | Select-Object -Unique)
}

function Start-NotifyBroker {
    if (-not (Test-Path -LiteralPath $script:NotifyBrokerScript)) {
        Write-NotifyListenerLog -Message 'broker-start-skip missing-broker-script'
        return $false
    }

    $existingBrokerPids = @(Get-NotifyBrokerProcessIds)
    if ($existingBrokerPids.Count -gt 0) {
        Write-NotifyListenerLog -Message ('broker-start-skip existing count={0}' -f $existingBrokerPids.Count)
        return $true
    }

    try {
        $brokerArgs = Join-NotifyBridgeProcessArguments @(
            '-NoProfile',
            '-STA',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script:NotifyBrokerScript,
            '-ConfigPath', $ConfigPath
        )
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:NotifyPowerShellExe
        $startInfo.Arguments = $brokerArgs
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        [void][System.Diagnostics.Process]::Start($startInfo)
        Write-NotifyListenerLog -Message ('broker-start-request port={0}' -f $config.BrokerPort)
        return $true
    }
    catch {
        Write-NotifyListenerLog -Message ('broker-start-error "{0}"' -f $_.Exception.Message)
        return $false
    }
}

function Send-NotifyBrokerPopup {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$SessionName,
        [Parameter(Mandatory = $true)][string]$TargetFingerprint,
        [int]$StackIndex,
        [int]$TimeoutSeconds,
        [string]$PopupPlacement,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    $payloadTable = @{
        title = $Title
        body = $Body
        focusTarget = $FocusTarget
        cwdBase = $CwdBase
        tabTitle = $TabTitle
        sessionName = $SessionName
        targetFingerprint = $TargetFingerprint
        stackIndex = $StackIndex
        timeoutSeconds = $TimeoutSeconds
        popupPlacement = $PopupPlacement
    }
    if (-not [string]::IsNullOrWhiteSpace($OriginKind)) { $payloadTable['originKind'] = $OriginKind }
    if (-not [string]::IsNullOrWhiteSpace($NotificationId)) { $payloadTable['notificationId'] = $NotificationId }
    if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) { $payloadTable['snapshotId'] = $SnapshotId }
    if (-not [string]::IsNullOrWhiteSpace($RecoveryTicketId)) { $payloadTable['recoveryTicketId'] = $RecoveryTicketId }
    $payload = $payloadTable | ConvertTo-Json -Depth 4 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $timeoutMs = [Math]::Max(300, [int]$config.BrokerRequestTimeoutMs)
    $port = [int]$config.BrokerPort
    $client = [System.Net.Sockets.TcpClient]::new()
    $connectHandle = $null
    try {
        $connectResult = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        $connectHandle = $connectResult.AsyncWaitHandle
        if (-not $connectHandle.WaitOne($timeoutMs)) {
            throw ('broker connect timeout after {0}ms' -f $timeoutMs)
        }
        $client.EndConnect($connectResult)
        $client.ReceiveTimeout = $timeoutMs
        $client.SendTimeout = $timeoutMs
        $requestHead = "POST /popup HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestHead)
        $stream = $client.GetStream()
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()

        $responseWaitMs = [Math]::Min(150, $timeoutMs)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($responseWaitMs)
        while (-not $stream.DataAvailable -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 10
        }
        if (-not $stream.DataAvailable) {
            Write-NotifyListenerLog -Message 'broker-post-accepted-no-response'
            return $true
        }

        $buffer = [byte[]]::new(256)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            Write-NotifyListenerLog -Message 'broker-post-accepted-empty-response'
            return $true
        }
        $responseText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        if ($responseText -notmatch '^HTTP/1\.1 200\b') {
            $firstLine = (($responseText -split "`r?`n") | Select-Object -First 1)
            throw ('broker returned {0}' -f $firstLine)
        }
        return $true
    }
    catch {
        Write-NotifyListenerLog -Message ('broker-post-error "{0}"' -f $_.Exception.Message)
        return $false
    }
    finally {
        if ($null -ne $connectHandle) { try { $connectHandle.Close() } catch {} }
        try { $client.Close() } catch {}
    }
}

function Invoke-NotifyBrokerPopup {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$SessionName,
        [Parameter(Mandatory = $true)][string]$TargetFingerprint,
        [int]$StackIndex,
        [int]$TimeoutSeconds,
        [string]$PopupPlacement,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    $brokerEnabled = $false
    if ($config.PSObject.Properties['BrokerEnabled']) {
        try { $brokerEnabled = [bool]$config.BrokerEnabled } catch { $brokerEnabled = $false }
    }
    if (-not $brokerEnabled) {
        return $false
    }

    if (-not (Test-NotifyBrokerHealth)) {
        Write-NotifyListenerLog -Message 'broker-health-miss attempting-start'
        $started = Start-NotifyBroker
        if ($started) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(100, [int]$config.BrokerStartupTimeoutMs))
            while ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
                if (Test-NotifyBrokerHealth) { break }
            }
        }
    }

    if (-not (Test-NotifyBrokerHealth)) {
        Write-NotifyListenerLog -Message 'broker-unavailable fallback=popup-process'
        return $false
    }

    $sent = Send-NotifyBrokerPopup -Title $Title -Body $Body -FocusTarget $FocusTarget -CwdBase $CwdBase -TabTitle $TabTitle -SessionName $SessionName -TargetFingerprint $TargetFingerprint -StackIndex $StackIndex -TimeoutSeconds $TimeoutSeconds -PopupPlacement $PopupPlacement -OriginKind $OriginKind -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId
    if (-not $sent) {
        Write-NotifyListenerLog -Message 'broker-post-failed fallback=popup-process'
        return $false
    }

    Write-NotifyListenerLog -Message ('broker-popup-sent targetFingerprint={0} slot={1} timeout={2} originKind={3} notificationFp={4} snapshotFp={5}' -f $TargetFingerprint, $StackIndex, $TimeoutSeconds, $(if ([string]::IsNullOrWhiteSpace($OriginKind)) { 'none' } else { $OriginKind }), (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $SnapshotId))
    return $true
}

function Start-NotifyPopupProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$SessionName,
        [Parameter(Mandatory = $true)][string]$TargetFingerprint,
        [int]$StackIndex,
        [int]$TimeoutSeconds,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    Clear-NotifyBridgePopupArtifacts -Aggressive
    $popupArguments = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-STA',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:NotifyPopupScript,
        '-ConfigPath', $ConfigPath,
        '-TargetFingerprint', $TargetFingerprint,
        '-StackIndex', $StackIndex,
        '-TimeoutSeconds', $TimeoutSeconds
    )
    $popupStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $popupStartInfo.FileName = $script:NotifyPowerShellExe
    $popupStartInfo.Arguments = $popupArguments
    $popupStartInfo.UseShellExecute = $false
    $popupStartInfo.CreateNoWindow = $true
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_TITLE'] = [string]$Title
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_BODY'] = [string]$Body
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_FOCUS_TARGET'] = [string]$FocusTarget
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_CWD_BASE'] = [string]$CwdBase
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_TAB_TITLE'] = [string]$TabTitle
    $popupStartInfo.EnvironmentVariables['PI_NOTIFY_SESSION_NAME'] = [string]$SessionName
    if (-not [string]::IsNullOrWhiteSpace($OriginKind)) {
        $popupStartInfo.EnvironmentVariables['PI_NOTIFY_ORIGIN_KIND'] = [string]$OriginKind
    }
    if (-not [string]::IsNullOrWhiteSpace($NotificationId)) {
        $popupStartInfo.EnvironmentVariables['PI_NOTIFY_NOTIFICATION_ID'] = [string]$NotificationId
    }
    if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) {
        $popupStartInfo.EnvironmentVariables['PI_NOTIFY_SNAPSHOT_ID'] = [string]$SnapshotId
    }
    if (-not [string]::IsNullOrWhiteSpace($RecoveryTicketId)) {
        $popupStartInfo.EnvironmentVariables['PI_NOTIFY_RECOVERY_TICKET_ID'] = [string]$RecoveryTicketId
    }
    $popupProcess = [System.Diagnostics.Process]::Start($popupStartInfo)
    Write-NotifyListenerLog -Message ('popup-pid {0} slot={1} targetFingerprint="{2}" originKind={3} notificationFp={4} snapshotFp={5}' -f $popupProcess.Id, $StackIndex, $TargetFingerprint, $(if ([string]::IsNullOrWhiteSpace($OriginKind)) { 'none' } else { $OriginKind }), (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $SnapshotId))
}

function Show-Toast {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [Parameter(Mandatory = $true)]
        [string]$ToastAppId,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle,
        [string]$SessionName,
        [string]$LaunchUri,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [string]$TargetFingerprint = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($TestDesktopSinkPath)) {
        $sinkPath = [System.IO.Path]::GetFullPath($TestDesktopSinkPath)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sinkPath) | Out-Null
        [System.IO.File]::AppendAllText($sinkPath, ('desktop-shown' + [System.Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        return
    }

    $originKind = if ([string]::IsNullOrWhiteSpace($OriginKind)) { '' } else { [string]$OriginKind }
    $focusTarget = if ($originKind -eq 'paseo') { '' } elseif ([string]::IsNullOrWhiteSpace($FocusTarget)) { [string]$config.RemoteHostAlias } else { [string]$FocusTarget }
    $cwdBase = if ([string]::IsNullOrWhiteSpace($CwdBase)) { '' } else { [string]$CwdBase }
    $tabTitle = if ([string]::IsNullOrWhiteSpace($TabTitle)) { '' } else { [string]$TabTitle }
    $sessionName = if ($originKind -eq 'paseo' -or [string]::IsNullOrWhiteSpace($SessionName)) { '' } else { [string]$SessionName }
    $notificationId = if ([string]::IsNullOrWhiteSpace($NotificationId)) { '' } else { [string]$NotificationId }
    $snapshotId = if ([string]::IsNullOrWhiteSpace($SnapshotId)) { '' } else { [string]$SnapshotId }
    $recoveryTicketId = if ([string]::IsNullOrWhiteSpace($RecoveryTicketId)) { '' } else { [string]$RecoveryTicketId }

    if ($DisplayMode -eq 'popup-focus' -and (Test-Path -LiteralPath $script:NotifyPopupScript)) {
        $targetKey = Get-NotifyPopupTargetKey -TargetHost $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle
        $targetFingerprint = if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) {
            [string]$TargetFingerprint
        } else {
            Get-NotifyPopupTargetFingerprint -TargetKey $targetKey
        }

        $brokerSent = Invoke-NotifyBrokerPopup -Title $Title -Body $Body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex -1 -TimeoutSeconds $PopupTimeoutSeconds -PopupPlacement ([string]$config.PopupPlacement) -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId
        if ($brokerSent) {
            return
        }

        $stackIndex = Get-NotifyPopupStackPlan -TargetKey $targetKey -TargetFingerprint $targetFingerprint
        Clear-NotifyBridgePopupArtifacts -Aggressive

        Write-NotifyListenerLog -Message ('popup-launch targetFingerprint={0} slot={1} timeout={2} source=fallback originKind={3}' -f $targetFingerprint, $stackIndex, $PopupTimeoutSeconds, $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'none' } else { $originKind }))
        Start-NotifyPopupProcess -Title $Title -Body $Body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex $stackIndex -TimeoutSeconds $PopupTimeoutSeconds -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId
        return
    }

    $type = 'Windows.UI.Notifications'
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null

    $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
    $texts = $xml.GetElementsByTagName('text')
    $texts.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
    $texts.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null

    $activationId = [Guid]::NewGuid().ToString('N')
    $activationTtlSeconds = if ($originKind -eq 'paseo') {
        Get-NotifyPaseoActivationTtlSeconds -Config $config -PopupTimeoutSeconds ([int]$PopupTimeoutSeconds)
    } else {
        600
    }
    $activationPaths = @(Save-NotifyToastActivationState -ActivationId $activationId -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId -TtlSeconds $activationTtlSeconds)
    if ($originKind -eq 'paseo' -and $activationPaths.Count -eq 0) {
        throw 'Paseo toast activation pointer cache is unavailable.'
    }
    $safeLaunchUri = Get-NotifyBridgeActivationUri -ActivationId $activationId
    $xml.DocumentElement.SetAttribute('launch', $safeLaunchUri)
    $xml.DocumentElement.SetAttribute('activationType', 'protocol')

    Write-NotifyListenerLog -Message ('system-toast activationId={0} hasCwd={1} hasTab={2} originKind={3} notificationFp={4} snapshotFp={5}' -f $activationId, (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)), $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'none' } else { $originKind }), (Get-NotifyRouteFingerprint -Value $notificationId), (Get-NotifyRouteFingerprint -Value $snapshotId))
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    if ($originKind -eq 'paseo') {
        # Exact close uses notification UUID as Tag and agent fingerprint as Group.
        # Remove prior same-agent toast(s) before showing so replacement stays agent-scoped.
        if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) {
            try {
                [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup($TargetFingerprint, $ToastAppId)
            }
            catch {
                # Best-effort only; display must still proceed.
            }
            $toast.Group = $TargetFingerprint
        }
        else {
            $toast.Group = 'paseo'
        }
        if (-not [string]::IsNullOrWhiteSpace($notificationId)) {
            $toast.Tag = $notificationId
        }
        elseif (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) {
            $toast.Tag = $TargetFingerprint
        }
    }
    $isPendingRecoveryToast = $originKind -eq 'pi-web' -and
        [string]::IsNullOrWhiteSpace($snapshotId) -and
        -not [string]::IsNullOrWhiteSpace($notificationId) -and
        -not [string]::IsNullOrWhiteSpace($recoveryTicketId)
    # A pending ticket is valid for 120 seconds from freeze. Expire the toast
    # slightly earlier so Windows cannot leave a dead clickable notification
    # behind after the Host has terminalized the ticket. Already-ready
    # snapshots retain the normal five-minute visibility window.
    $toast.ExpirationTime = if ($isPendingRecoveryToast) {
        [DateTimeOffset]::Now.AddSeconds(115)
    }
    elseif ($originKind -eq 'paseo') {
        [DateTimeOffset]::Now.AddSeconds($activationTtlSeconds)
    }
    else {
        [DateTimeOffset]::Now.AddMinutes(5)
    }
    # Windows PowerShell 5.1 cannot reliably subscribe to WinRT toast events.
    # Click activation is handled by the protocol launch URI above.
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
    if ($isPendingRecoveryToast) {
        [void](Start-NotifyToastRecoveryWorker -ActivationId $activationId -NotificationId $notificationId -RecoveryTicketId $recoveryTicketId -ActivationPaths $activationPaths)
    }
}

$ipAddress = [System.Net.IPAddress]::Parse($ListenHost)
$listener = [System.Net.Sockets.TcpListener]::new($ipAddress, $Port)
$listener.Server.ReceiveTimeout = 15000
$listener.Server.SendTimeout = 15000
$listener.Start()

Write-Host (("Pi notify listener running at http://{0}:{1}/notify" -f $ListenHost, $Port))
Write-Host "Config: $ConfigPath"
Write-Host "Remote endpoint through ssh -R: $($config.RemoteUrl)"
Write-NotifyListenerLog -Message ('listener-start url={0} config="{1}" mode={2}' -f $config.LocalUrl, $ConfigPath, $DisplayMode)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $notified = $false
        try {
            $client.ReceiveTimeout = 15000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream

            $parts = $request.RequestLine.Split(' ', 3)
            $method = if ($parts.Length -ge 1) { $parts[0].ToUpperInvariant() } else { '' }
            $path = if ($parts.Length -ge 2) { $parts[1] } else { '/' }

            if ($method -eq 'GET' -and $path -eq '/health') {
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body '{"ok":true}' -ContentType 'application/json; charset=utf-8'
                continue
            }

            if ($method -ne 'POST') {
                Write-HttpResponse -Stream $stream -StatusCode 405 -Reason 'Method Not Allowed' -Body 'method not allowed'
                continue
            }

            if ($path -notin @('/', '/notify', '/paseo/health', '/paseo/close')) {
                Write-HttpResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -Body 'not found'
                continue
            }

            $headerToken = [string]$request.Headers['X-Pi-Notify-Token']
            if ($headerToken -ne $Token) {
                Write-HttpResponse -Stream $stream -StatusCode 403 -Reason 'Forbidden' -Body 'forbidden'
                continue
            }

            $bodyText = if ($request.BodyBytes.Length -gt 0) {
                [System.Text.Encoding]::UTF8.GetString($request.BodyBytes)
            }
            else {
                ''
            }

            # Authenticated capability health: fixed schema only, side-effect free.
            if ($path -eq '/paseo/health') {
                try {
                    $health = Get-NotifyPaseoHealthSnapshot -Config $config -DisplayMode ([string]$DisplayMode)
                    $healthJson = ConvertTo-NotifyPaseoHealthJson -Snapshot $health
                    Write-NotifyListenerLog -Message ('paseo-health ready={0} displayReady={1} routeReady={2} routeState={3}' -f $health.ready, $health.displayReady, $health.routeReady, $health.routeState)
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $healthJson -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-NotifyListenerLog -Message ('paseo-health-error reason={0}' -f $_.Exception.GetType().Name)
                    $fallback = ConvertTo-NotifyPaseoHealthJson -Snapshot ([pscustomobject]@{
                            version = 1; ready = $false; listenerReady = $true; displayReady = $false; routeReady = $false; routeState = 'probe-error'
                        })
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $fallback -ContentType 'application/json; charset=utf-8'
                }
                continue
            }

            # Exact idempotent permission close by notification UUID only.
            if ($path -eq '/paseo/close') {
                $closePayload = $null
                if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                    try { $closePayload = $bodyText | ConvertFrom-Json } catch { $closePayload = $null }
                }
                $closeReq = Resolve-NotifyPaseoCloseRequest -Payload $closePayload
                if (-not $closeReq.IsValid) {
                    Write-NotifyListenerLog -Message ('paseo-close-invalid reason={0} notificationFp={1}' -f $(if ([string]::IsNullOrWhiteSpace($closeReq.InvalidReason)) { 'invalid' } else { $closeReq.InvalidReason }), (Get-NotifyRouteFingerprint -Value $closeReq.NotificationId))
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'invalid'
                    continue
                }
                try {
                    $closeResult = Invoke-NotifyPaseoCloseByNotificationId -NotificationId $closeReq.NotificationId -Config $config -ToastAppId $AppId
                    if ($closeResult.Ok) {
                        Write-NotifyListenerLog -Message ('paseo-close result=ok notificationFp={0} removedActivations={1}' -f $closeResult.NotificationFp, $closeResult.RemovedActivations)
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'ok'
                    }
                    else {
                        $closeBody = if ([string]$closeResult.Result -eq 'invalid') { 'invalid' } else { 'retry' }
                        Write-NotifyListenerLog -Message ('paseo-close result={0} notificationFp={1}' -f $closeBody, $closeResult.NotificationFp)
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $closeBody
                    }
                }
                catch {
                    Write-NotifyListenerLog -Message ('paseo-close-error reason={0} notificationFp={1}' -f $_.Exception.GetType().Name, (Get-NotifyRouteFingerprint -Value $closeReq.NotificationId))
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'retry'
                }
                continue
            }

            $payload = $null
            if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $payload = $bodyText | ConvertFrom-Json
            }

            $title = 'Pi'
            $body = 'Ready for input'
            $focusTarget = [string]$config.RemoteHostAlias
            $cwdBase = ''
            $tabTitle = ''
            $sessionName = ''
            if ($null -ne $payload) {
                if ($payload.PSObject.Properties['title'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.title)) {
                    $title = [string]$payload.title
                }
                if ($payload.PSObject.Properties['body'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.body)) {
                    $body = [string]$payload.body
                }
                if ($payload.PSObject.Properties['focusTarget'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.focusTarget)) {
                    $focusTarget = [string]$payload.focusTarget
                }
                if ($payload.PSObject.Properties['cwdBase'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.cwdBase)) {
                    $cwdBase = [string]$payload.cwdBase
                }
                if ($payload.PSObject.Properties['tabTitle'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.tabTitle)) {
                    $tabTitle = [string]$payload.tabTitle
                }
                if ($payload.PSObject.Properties['sessionName'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.sessionName)) {
                    $sessionName = [string]$payload.sessionName
                }
            }
            $title = if ([string]::IsNullOrWhiteSpace($title)) { 'Pi' } else { $title.Trim() }
            $body = if ([string]::IsNullOrWhiteSpace($body)) { 'Ready for input' } else { $body.Trim() }
            $sessionName = if ([string]::IsNullOrWhiteSpace($sessionName)) { '' } else { $sessionName.Trim() }
            if ([string]::IsNullOrWhiteSpace($cwdBase) -and $body -match '(?i)\bcwd\s*[:=]\s*([^|\u00B7]+)') {
                $cwdValue = $Matches[1].Trim().Trim('"')
                $cwdBase = if ([string]::IsNullOrWhiteSpace($cwdValue)) { '' } else { Split-Path -Leaf $cwdValue }
            }
            if ($cwdBase.Trim() -match '^\{[^}]+\}$') { $cwdBase = '' }
            if ($tabTitle.Trim() -match '^\{[^}]+\}$') { $tabTitle = '' }

            # Optional exact-route metadata (additive). Valid pi-web freezes immediately; only
            # notificationId + snapshotId + originKind are retained for click paths.
            # Paseo is a separate origin: raw route triples never leave listener scope except DPAPI cache.
            $declaredOrigin = ''
            if ($null -ne $payload -and $payload.PSObject.Properties['originKind'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.originKind)) {
                $declaredOrigin = ([string]$payload.originKind).Trim()
            }
            $routeOriginKind = ''
            $routeNotificationId = ''
            $routeSnapshotId = ''
            $routeRecoveryTicketId = ''
            $suppressTerminalFallback = $false
            $paseoTargetFingerprint = ''
            $paseoDedupChecked = $false

            if ($declaredOrigin -eq 'paseo') {
                $paseoMeta = Resolve-NotifyPaseoRouteMetadata -Payload $payload
                if ($paseoMeta.IsValidPaseoExact) {
                    $paseoTargetFingerprint = Get-NotifyPaseoTargetFingerprint -ServerId $paseoMeta.ServerId -AgentId $paseoMeta.AgentId
                    # A resolved UUID wins before foreground suppression so permission replay is terminal dedup.
                    if (Test-NotifyPaseoCloseTombstone -NotificationId $paseoMeta.NotificationId) {
                        Write-NotifyListenerLog -Message ('paseo-close-tombstone-hit notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId))
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'dedup'
                        continue
                    }

                    $foreground = Test-NotifyPaseoForegroundActiveAgent -ServerId $paseoMeta.ServerId -AgentId $paseoMeta.AgentId -Config $config
                    if ($foreground.State -eq 'active') {
                        Write-NotifyListenerLog -Message ('paseo-suppressed-active-agent notificationFp={0} result={1}' -f (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId), $(if ([string]::IsNullOrWhiteSpace([string]$foreground.Result)) { 'exact-agent-focused' } else { [string]$foreground.Result }))
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'suppressed-active-agent'
                        continue
                    }

                    if (Test-NotifyDuplicateDrop -Title $title -Body $body -FocusTarget $paseoTargetFingerprint -CwdBase '' -TabTitle '' -OriginKind 'paseo' -CheckOnly) {
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'dedup'
                        continue
                    }
                    $paseoDedupChecked = $true

                    $paseoActivationId = [Guid]::NewGuid().ToString('N')
                    $ttlSeconds = Get-NotifyPaseoActivationTtlSeconds -Config $config -PopupTimeoutSeconds ([int]$PopupTimeoutSeconds)
                    $activationSave = Save-NotifyPaseoActivationUnlessClosed -ActivationId $paseoActivationId -NotificationId $paseoMeta.NotificationId -NotificationKind $paseoMeta.NotificationKind -ServerId $paseoMeta.ServerId -WorkspaceId $paseoMeta.WorkspaceId -AgentId $paseoMeta.AgentId -TtlSeconds $ttlSeconds
                    if ($activationSave.Result -eq 'closed') {
                        Write-NotifyListenerLog -Message ('paseo-close-race-dedup notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId))
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'dedup'
                        continue
                    }
                    if (-not $activationSave.Ok) {
                        # Cache write failure: do not display a non-activatable card; sender may retry.
                        Write-NotifyListenerLog -Message ('paseo-activation-cache-error result=retry reason=cache-write notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId))
                        Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'retry'
                        continue
                    }

                    $routeOriginKind = 'paseo'
                    $routeNotificationId = $paseoMeta.NotificationId
                    $routeSnapshotId = $paseoActivationId
                    $suppressTerminalFallback = $true
                    Write-NotifyListenerLog -Message ('notify-received originKind=paseo notificationFp={0} activationFp={1} kind={2} result=accepted' -f (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId), (Get-NotifyRouteFingerprint -Value $paseoActivationId), $paseoMeta.NotificationKind)
                }
                else {
                    $routeOriginKind = 'paseo'
                    $routeNotificationId = $(if ($paseoMeta.NotificationId) { $paseoMeta.NotificationId } else { '' })
                    $routeSnapshotId = ''
                    $suppressTerminalFallback = $true
                    Write-NotifyListenerLog -Message ('paseo-route-metadata-invalid reason={0} notificationFp={1}' -f $(if ([string]::IsNullOrWhiteSpace($paseoMeta.InvalidReason)) { 'invalid' } else { $paseoMeta.InvalidReason }), (Get-NotifyRouteFingerprint -Value $paseoMeta.NotificationId))
                    # error / invalid paseo payloads never display and never fall into other origins.
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'invalid'
                    continue
                }
            }
            else {
                $routeMeta = Resolve-NotifyExactRouteMetadata -Payload $payload
                if ($routeMeta.HasAnyRouteField) {
                    if ($routeMeta.IsValidPiWebExact) {
                        Write-NotifyListenerLog -Message ('notify-received originKind=pi-web notificationFp={0} instanceFp={1} routingFp={2} kind={3}' -f (Get-NotifyRouteFingerprint -Value $routeMeta.NotificationId), (Get-NotifyRouteFingerprint -Value $routeMeta.InstanceKey), (Get-NotifyRouteFingerprint -Value $routeMeta.RoutingKey), $(if ([string]::IsNullOrWhiteSpace($routeMeta.NotificationKind)) { 'none' } else { $routeMeta.NotificationKind }))
                        $freezeDecision = Invoke-NotifyExactRouteFreeze -NotificationId $routeMeta.NotificationId -NotificationKind $routeMeta.NotificationKind -InstanceKey $routeMeta.InstanceKey -RoutingKey $routeMeta.RoutingKey -Config $config
                        Write-NotifyListenerLog -Message ('route-freeze decision={0} result={1} reason={2} notificationFp={3} snapshotFp={4}' -f $freezeDecision.Decision, $freezeDecision.Result, $(if ([string]::IsNullOrWhiteSpace($freezeDecision.Reason)) { 'none' } else { $freezeDecision.Reason }), (Get-NotifyRouteFingerprint -Value $routeMeta.NotificationId), (Get-NotifyRouteFingerprint -Value $freezeDecision.SnapshotId))
                        if ($freezeDecision.Decision -eq 'exact-ready') {
                            $routeOriginKind = 'pi-web'
                            $routeNotificationId = $routeMeta.NotificationId
                            $routeSnapshotId = $freezeDecision.SnapshotId
                        }
                        elseif ($freezeDecision.Decision -eq 'exact-recovering') {
                            $routeOriginKind = 'pi-web'
                            $routeNotificationId = $routeMeta.NotificationId
                            $routeSnapshotId = ''
                            $routeRecoveryTicketId = $freezeDecision.RecoveryTicketId
                            $suppressTerminalFallback = $true
                            Write-NotifyListenerLog -Message ('route-freeze-recovering notificationFp={0} ticketFp={1}' -f (Get-NotifyRouteFingerprint -Value $routeMeta.NotificationId), (Get-NotifyRouteFingerprint -Value $routeRecoveryTicketId))
                        }
                        else {
                            # Preserve the declared origin so every Pi Web route failure is a click no-op.
                            $routeOriginKind = 'pi-web'
                            $routeNotificationId = $routeMeta.NotificationId
                            $routeSnapshotId = ''
                            $suppressTerminalFallback = $true
                            Write-NotifyListenerLog -Message ('route-freeze-fail-closed result={0} reason={1} notificationFp={2}' -f $freezeDecision.Result, $(if ([string]::IsNullOrWhiteSpace($freezeDecision.Reason)) { 'none' } else { $freezeDecision.Reason }), (Get-NotifyRouteFingerprint -Value $routeMeta.NotificationId))
                        }
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($routeMeta.InvalidReason)) {
                        Write-NotifyListenerLog -Message ('route-metadata-invalid reason={0}' -f $routeMeta.InvalidReason)
                        if ($routeMeta.OriginKind -ne 'terminal') {
                            # Unknown or malformed Web route metadata must not be reinterpreted as Terminal.
                            $routeOriginKind = 'pi-web'
                            $routeNotificationId = ''
                            $routeSnapshotId = ''
                            $suppressTerminalFallback = $true
                        }
                    }
                }
            }

            if ($DisplayMode -eq 'popup-focus' -and [string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle) -and [string]::IsNullOrWhiteSpace($routeSnapshotId) -and -not $suppressTerminalFallback -and $routeOriginKind -ne 'paseo') {
                Write-NotifyListenerLog -Message ('notify-drop missing-target-metadata targetFingerprint="{0}"' -f (Get-NotifyPopupTargetFingerprint -TargetKey $focusTarget))
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'no-target'
                continue
            }
            if (-not $paseoDedupChecked -and (Test-NotifyDuplicateDrop -Title $title -Body $body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -OriginKind $routeOriginKind)) {
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'dedup'
                continue
            }

            $launchUri = Get-NotifyBridgeActivationUri -ActivationId ([Guid]::NewGuid().ToString('N'))
            $displayTargetFingerprint = if ($routeOriginKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($paseoTargetFingerprint)) {
                $paseoTargetFingerprint
            } else {
                (Get-NotifyPopupTargetFingerprint -TargetKey $focusTarget)
            }

            Write-NotifyListenerLog -Message ('notify targetFingerprint="{0}" hasCwd={1} hasTab={2} originKind={3} notificationFp={4} snapshotFp={5}' -f $displayTargetFingerprint, (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)), $(if ([string]::IsNullOrWhiteSpace($routeOriginKind)) { 'none' } else { $routeOriginKind }), (Get-NotifyRouteFingerprint -Value $routeNotificationId), (Get-NotifyRouteFingerprint -Value $routeSnapshotId))
            if ($routeOriginKind -eq 'paseo') {
                # Agent fingerprint drives same-agent replacement / different-agent stack.
                # Route transports contain only the opaque activation handle; Terminal metadata is blank.
                try {
                    Show-Toast -Title $title -Body $body -ToastAppId $AppId -FocusTarget '' -CwdBase '' -TabTitle '' -SessionName '' -LaunchUri $launchUri -OriginKind 'paseo' -NotificationId $routeNotificationId -SnapshotId $routeSnapshotId -RecoveryTicketId '' -TargetFingerprint $displayTargetFingerprint
                }
                catch {
                    Write-NotifyListenerLog -Message ('paseo-display-error result=retry reason={0} notificationFp={1}' -f $_.Exception.GetType().Name, (Get-NotifyRouteFingerprint -Value $routeNotificationId))
                    Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'retry'
                    continue
                }
                # Record five-second dedup only after the desktop path accepted the display.
                [void](Test-NotifyDuplicateDrop -Title $title -Body $body -FocusTarget $paseoTargetFingerprint -CwdBase '' -TabTitle '' -OriginKind 'paseo')
            }
            else {
                Show-Toast -Title $title -Body $body -ToastAppId $AppId -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -LaunchUri $launchUri -OriginKind $routeOriginKind -NotificationId $routeNotificationId -SnapshotId $routeSnapshotId -RecoveryTicketId $routeRecoveryTicketId
            }
            $notified = $true
            try {
                # Paseo stays off the QQ mirror path; Terminal/Pi Web keep the single post-desktop dispatch.
                if ($routeOriginKind -ne 'paseo') {
                    Start-NotifyQqDispatch -Title $title -Body $body
                }
            }
            catch {
                Write-NotifyListenerLog -Message ('qq-send-error reason={0}' -f $_.Exception.GetType().Name)
            }
            Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'ok'
        }
        catch {
            if (Test-NotifyListenerClientDisconnect -Exception $_.Exception) {
                Write-NotifyListenerLog -Message 'client-disconnect'
            }
            else {
                try {
                    if ($stream) {
                        Write-HttpResponse -Stream $stream -StatusCode 500 -Reason 'Internal Server Error' -Body 'error'
                    }
                }
                catch {
                }
                Write-NotifyListenerLog -Message ('error reason={0}' -f $_.Exception.GetType().Name)
            }
        }
        finally {
            try {
                $client.Close()
            }
            catch {
            }
        }

        if ($Once -and $notified) {
            break
        }
    }
}
finally {
    try {
        $listener.Stop()
    }
    catch {
    }
    Clear-NotifyToastRecoveryWorkers
    foreach ($worker in @($script:NotifyToastRecoveryWorkers)) {
        try { $worker.PowerShell.Stop() } catch {}
        try { $worker.PowerShell.Dispose() } catch {}
        try { $worker.Runspace.Close(); $worker.Runspace.Dispose() } catch {}
    }
    $script:NotifyToastRecoveryWorkers.Clear()
}
