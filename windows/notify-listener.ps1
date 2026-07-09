[CmdletBinding()]
param(
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$ConfigPath,
    [string]$AppId = "Pi Remote",
    [switch]$Once
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
$script:NotifyActivationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
$script:NotifyPopupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
$script:NotifyBrokerScript = Join-Path $PSScriptRoot 'pi-notify-broker.ps1'
$script:NotifyPowerShellExe = Get-NotifyBridgePowerShellExe
$script:NotifyListenerLogPath = Join-Path (Get-NotifyBridgeLogDir) 'listener.log'
$script:NotifyRecentNotifications = @()
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
        [string]$TabTitle
    )

    try {
        $logDirs = @((Get-NotifyBridgeLogDir), (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs')) | Select-Object -Unique
        $payload = @{
            activationId   = $ActivationId
            protectedHost  = Protect-NotifyActivationValue -Value $FocusTarget
            protectedCwd   = Protect-NotifyActivationValue -Value $CwdBase
            protectedTab   = Protect-NotifyActivationValue -Value $TabTitle
            expiresAtTicks = [DateTime]::UtcNow.AddMinutes(10).Ticks
        }
        $writtenPaths = @()
        foreach ($logDir in $logDirs) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue)) {
                if ($item.LastWriteTime -lt (Get-Date).AddMinutes(-10)) {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            $path = Join-Path $logDir ('activation-{0}.json' -f $ActivationId)
            [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
            $writtenPaths += $path
        }
        $cleanupTimer = [System.Threading.Timer]::new([System.Threading.TimerCallback]{
            param($state)
            foreach ($path in @($state)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {} }
        }, @($writtenPaths), [TimeSpan]::FromMinutes(10), [System.Threading.Timeout]::InfiniteTimeSpan)
        [void]$script:NotifyActivationCleanupTimers.Add($cleanupTimer)
        while ($script:NotifyActivationCleanupTimers.Count -gt 96) {
            try { $script:NotifyActivationCleanupTimers[0].Dispose() } catch {}
            $script:NotifyActivationCleanupTimers.RemoveAt(0)
        }
        return @($writtenPaths)
    }
    catch {
        Write-NotifyListenerLog -Message ('activation-cache-write-error "{0}"' -f $_.Exception.Message)
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

function Get-NotifyPopupPayloadPathFromCommandLine {
    param([string]$CommandLine)
    return Get-NotifyCommandLineArgument -CommandLine $CommandLine -Name 'PayloadPath'
}

function Test-NotifyPathUnderDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        return ($fullPath.Equals($fullDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith(($fullDirectory + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase))
    }
    catch {
        return $false
    }
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
        [string]$TargetKey
    )

    $targetFingerprint = Get-NotifyPopupTargetFingerprint -TargetKey $TargetKey
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
        [string]$TabTitle
    )

    $now = Get-Date
    $precise = -not [string]::IsNullOrWhiteSpace($CwdBase) -or -not [string]::IsNullOrWhiteSpace($TabTitle)
    $signature = ('{0}`n{1}`n{2}' -f ([string]$FocusTarget).Trim().ToLowerInvariant(), $Title.Trim(), $Body.Trim())
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

    $script:NotifyRecentNotifications += [pscustomobject]@{
        Time      = $now
        Signature = $signature
        Precise   = $precise
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
        [string]$PopupPlacement
    )

    $payload = @{
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
    } | ConvertTo-Json -Depth 4 -Compress
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
        $buffer = [byte[]]::new(256)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw 'broker returned an empty response.' }
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
        [string]$PopupPlacement
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

    $sent = Send-NotifyBrokerPopup -Title $Title -Body $Body -FocusTarget $FocusTarget -CwdBase $CwdBase -TabTitle $TabTitle -SessionName $SessionName -TargetFingerprint $TargetFingerprint -StackIndex $StackIndex -TimeoutSeconds $TimeoutSeconds -PopupPlacement $PopupPlacement
    if (-not $sent) {
        Write-NotifyListenerLog -Message 'broker-post-failed fallback=popup-process'
        return $false
    }

    Write-NotifyListenerLog -Message ('broker-popup-sent targetFingerprint={0} slot={1} timeout={2}' -f $TargetFingerprint, $StackIndex, $TimeoutSeconds)
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
        [int]$TimeoutSeconds
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
    $popupProcess = [System.Diagnostics.Process]::Start($popupStartInfo)
    Write-NotifyListenerLog -Message ('popup-pid {0} slot={1} targetFingerprint="{2}"' -f $popupProcess.Id, $StackIndex, $TargetFingerprint)
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
        [string]$LaunchUri
    )

    $focusTarget = if ([string]::IsNullOrWhiteSpace($FocusTarget)) { [string]$config.RemoteHostAlias } else { [string]$FocusTarget }
    $cwdBase = if ([string]::IsNullOrWhiteSpace($CwdBase)) { '' } else { [string]$CwdBase }
    $tabTitle = if ([string]::IsNullOrWhiteSpace($TabTitle)) { '' } else { [string]$TabTitle }
    $sessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) { '' } else { [string]$SessionName }

    if ($DisplayMode -eq 'popup-focus' -and (Test-Path -LiteralPath $script:NotifyPopupScript)) {
        $targetKey = Get-NotifyPopupTargetKey -TargetHost $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle
        $targetFingerprint = Get-NotifyPopupTargetFingerprint -TargetKey $targetKey

        $brokerSent = Invoke-NotifyBrokerPopup -Title $Title -Body $Body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex -1 -TimeoutSeconds $PopupTimeoutSeconds -PopupPlacement ([string]$config.PopupPlacement)
        if ($brokerSent) {
            return
        }

        $stackIndex = Get-NotifyPopupStackPlan -TargetKey $targetKey
        Clear-NotifyBridgePopupArtifacts -Aggressive

        Write-NotifyListenerLog -Message ('popup-launch targetFingerprint={0} slot={1} timeout={2} source=fallback' -f $targetFingerprint, $stackIndex, $PopupTimeoutSeconds)
        Start-NotifyPopupProcess -Title $Title -Body $Body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex $stackIndex -TimeoutSeconds $PopupTimeoutSeconds
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
    $activationPaths = @(Save-NotifyToastActivationState -ActivationId $activationId -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle)
    $safeLaunchUri = Get-NotifyBridgeActivationUri -ActivationId $activationId
    $xml.DocumentElement.SetAttribute('launch', $safeLaunchUri)
    $xml.DocumentElement.SetAttribute('activationType', 'protocol')

    Write-NotifyListenerLog -Message ('system-toast activationId={0} hasCwd={1} hasTab={2}' -f $activationId, (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)))
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(5)
    # Windows PowerShell 5.1 cannot reliably subscribe to WinRT toast events.
    # Click activation is handled by the protocol launch URI above.
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
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

            if ($path -notin @('/', '/notify')) {
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
            if ($DisplayMode -eq 'popup-focus' -and [string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle)) {
                Write-NotifyListenerLog -Message ('notify-drop missing-target-metadata targetFingerprint="{0}"' -f (Get-NotifyPopupTargetFingerprint -TargetKey $focusTarget))
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'no-target'
                continue
            }
            if (Test-NotifyDuplicateDrop -Title $title -Body $body -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle) {
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'dedup'
                continue
            }

            $launchUri = Get-NotifyBridgeActivationUri -ActivationId ([Guid]::NewGuid().ToString('N'))

            Write-NotifyListenerLog -Message ('notify targetFingerprint="{0}" hasCwd={1} hasTab={2}' -f (Get-NotifyPopupTargetFingerprint -TargetKey $focusTarget), (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)))
            Show-Toast -Title $title -Body $body -ToastAppId $AppId -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle -SessionName $sessionName -LaunchUri $launchUri
            $notified = $true
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
                Write-NotifyListenerLog -Message ('error "{0}"' -f $_.Exception.Message)
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
}
