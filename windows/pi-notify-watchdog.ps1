[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$StartupDelaySeconds = 20,
    [int]$IntervalSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs

$script:NotifyWatchdogLogPath = Join-Path (Get-NotifyBridgeLogDir) 'watchdog.log'
$script:NotifyWatchdogPidPath = Join-Path (Get-NotifyBridgeBaseDir) 'watchdog.pid'
$script:NotifyWatchdogMutex = $null
$script:NotifyWatchdogHasLock = $false
$script:NotifyWatchdogListenerMisses = 0
$script:NotifyWatchdogTunnelMisses = 0
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyWatchdogLogPath) | Out-Null

function Write-NotifyWatchdogLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyWatchdogLogPath -Value $line -Encoding UTF8
}

function Test-NotifyListenerHealth {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($config.LocalUrl -replace '/notify$', '/health') -TimeoutSec 4
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Test-NotifyRemoteTunnel {
    $probe = @"
python3 - <<'PY'
import urllib.request
with urllib.request.urlopen('http://127.0.0.1:$($config.Port)/health', timeout=4) as r:
    print('HTTP', r.status)
PY
"@
    try {
        $output = & $config.SshExecutable -T -o BatchMode=yes -o ConnectTimeout=10 $config.RemoteHostAlias $probe 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Test-NotifyCommandLineContainsPath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $needle = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $start = 0
    while ($start -lt $CommandLine.Length) {
        $index = $CommandLine.IndexOf($needle, $start, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { return $false }
        $end = $index + $needle.Length
        if ($end -ge $CommandLine.Length) { return $true }
        $next = [string]$CommandLine[$end]
        if ([char]::IsWhiteSpace($CommandLine[$end]) -or $next -eq '"' -or $next -eq "'" -or $next -eq '\' -or $next -eq '/') { return $true }
        $start = $index + 1
    }
    return $false
}

function Test-NotifyProcessOwnedByThisInstance {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($needle in @($config.ConfigPath, (Get-NotifyBridgeBinDir), (Get-NotifyBridgeBaseDir))) {
        if (Test-NotifyCommandLineContainsPath -CommandLine $CommandLine -Path ([string]$needle)) { return $true }
    }
    return $false
}

function Get-NotifyProcessIds {
    param([string]$Pattern)
    $processIds = @()
    $scriptName = ''
    $scriptMatch = [regex]::Match($Pattern, '([A-Za-z0-9-]+\.ps1)')
    if ($scriptMatch.Success) {
        $scriptName = $scriptMatch.Groups[1].Value
    }

    try {
        $items = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $commandLine = [string]$_.CommandLine
            if (-not [string]::IsNullOrWhiteSpace($scriptName)) {
                $escaped = [regex]::Escape($scriptName)
                return ((Test-NotifyProcessOwnedByThisInstance -CommandLine $commandLine) -and ($commandLine -match ('(?i)-File\s+("[^"]*{0}"|[^\s"]*{0})' -f $escaped)))
            }
            return $commandLine -like $Pattern
        } | Select-Object -ExpandProperty ProcessId
        foreach ($processId in $items) {
            if ($processId) { $processIds += [int]$processId }
        }
    }
    catch {
    }
    return @($processIds | Select-Object -Unique)
}

function Test-NotifyProcessSafeToStop {
    param(
        [int]$ProcessId,
        [int[]]$AllowedSshParentProcessIds = @()
    )

    try {
        $processInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -eq $processInfo) { return $false }
        $commandLine = [string]$processInfo.CommandLine
        if (Test-NotifyProcessOwnedByThisInstance -CommandLine $commandLine) { return $true }
        if ([string]$processInfo.Name -eq 'ssh.exe' -and (@($AllowedSshParentProcessIds) -contains [int]$processInfo.ParentProcessId)) {
            $parent = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f ([int]$processInfo.ParentProcessId)) -ErrorAction SilentlyContinue
            return ($null -ne $parent -and (Test-NotifyProcessOwnedByThisInstance -CommandLine ([string]$parent.CommandLine)) -and ([string]$parent.CommandLine -like '*pi-notify-reverse-tunnel.ps1*'))
        }
    }
    catch {
    }
    return $false
}

function Stop-NotifyProcessGroup {
    param(
        [int[]]$ProcessIds,
        [int[]]$AllowedSshParentProcessIds = @()
    )
    foreach ($processId in @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        try {
            if (-not (Test-NotifyProcessSafeToStop -ProcessId $processId -AllowedSshParentProcessIds $AllowedSshParentProcessIds)) {
                Write-NotifyWatchdogLog -Message ('skip-unowned-taskkill pid={0}' -f $processId)
                continue
            }
            Start-Process -FilePath 'taskkill.exe' -ArgumentList (Join-NotifyBridgeProcessArguments @('/PID', $processId, '/F', '/T')) -WindowStyle Hidden -Wait | Out-Null
            Write-NotifyWatchdogLog -Message ('taskkill pid={0}' -f $processId)
        }
        catch {
        }
    }
}

function Merge-NotifyProcessIds {
    param(
        $First,
        $Second
    )

    $merged = @()
    foreach ($source in @($First, $Second)) {
        foreach ($processId in @($source)) {
            if ($processId) { $merged += [int]$processId }
        }
    }
    return @($merged | Where-Object { $_ -gt 0 } | Select-Object -Unique)
}

function Enter-NotifyWatchdogSingleton {
    $mutexName = 'Global\PiNotifyWatchdog_{0}' -f $config.Port
    $script:NotifyWatchdogMutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        $script:NotifyWatchdogHasLock = $script:NotifyWatchdogMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:NotifyWatchdogHasLock = $true
    }

    if (-not $script:NotifyWatchdogHasLock) {
        Write-NotifyWatchdogLog -Message ('watchdog-singleton-exit port={0} pid={1}' -f $config.Port, $PID)
        exit 0
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyWatchdogPidPath) | Out-Null
    Set-Content -LiteralPath $script:NotifyWatchdogPidPath -Value ([string]$PID) -Encoding ASCII
}

function Exit-NotifyWatchdogSingleton {
    try {
        if (Test-Path -LiteralPath $script:NotifyWatchdogPidPath) {
            $current = [string](Get-Content -LiteralPath $script:NotifyWatchdogPidPath -Raw -ErrorAction SilentlyContinue)
            if ($current.Trim() -eq [string]$PID) {
                Remove-Item -LiteralPath $script:NotifyWatchdogPidPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
    }

    if ($script:NotifyWatchdogHasLock -and $null -ne $script:NotifyWatchdogMutex) {
        try { $script:NotifyWatchdogMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:NotifyWatchdogMutex) {
        $script:NotifyWatchdogMutex.Dispose()
    }
}

function Start-NotifyScript {
    param([string]$ScriptName)
    $scriptPath = Join-Path (Get-NotifyBridgeBinDir) $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-NotifyWatchdogLog -Message ('missing-script "{0}"' -f $scriptPath)
        return
    }
    Start-Process -FilePath (Get-NotifyBridgePowerShellExe) -WindowStyle Hidden -ArgumentList (Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-ConfigPath', $config.ConfigPath
    )) | Out-Null
    Write-NotifyWatchdogLog -Message ('start-script {0}' -f $ScriptName)
}

Enter-NotifyWatchdogSingleton
try {
Write-NotifyWatchdogLog -Message ('watchdog-start startupDelay={0}s interval={1}s' -f $StartupDelaySeconds, $IntervalSeconds)
if ($StartupDelaySeconds -gt 0) {
    Start-Sleep -Seconds $StartupDelaySeconds
}

while ($true) {
    try {
        $listenerOk = Test-NotifyListenerHealth
        $tunnelOk = Test-NotifyRemoteTunnel
        Write-NotifyWatchdogLog -Message ('health listener={0} tunnel={1}' -f $listenerOk, $tunnelOk)

        $directListenerPids = Get-NotifyProcessIds -Pattern '*notify-listener.ps1*'
        $listenerRunnerPids = Get-NotifyProcessIds -Pattern '*pi-notify-listener-runner.ps1*'
        $pidFileOk = $false
        $listenerPidPath = Join-Path (Get-NotifyBridgeBaseDir) 'listener.pid'
        if (Test-Path -LiteralPath $listenerPidPath) {
            $rawListenerPid = [string](Get-Content -LiteralPath $listenerPidPath -Raw -ErrorAction SilentlyContinue)
            $listenerPidValue = 0
            if ([int]::TryParse($rawListenerPid.Trim(), [ref]$listenerPidValue)) {
                $pidFileOk = @($listenerRunnerPids | Where-Object { $_ -eq $listenerPidValue }).Count -eq 1
            }
        }
        $staleListener = @($directListenerPids).Count -gt 0 -or @($listenerRunnerPids).Count -ne 1 -or -not $pidFileOk
        if (-not $listenerOk -or $staleListener) {
            $script:NotifyWatchdogListenerMisses += 1
        }
        else {
            $script:NotifyWatchdogListenerMisses = 0
        }
        if ($script:NotifyWatchdogListenerMisses -ge 2) {
            Write-NotifyWatchdogLog -Message ('stale-listener direct={0} runner={1} pidFileOk={2} misses={3}' -f (@($directListenerPids).Count), (@($listenerRunnerPids).Count), $pidFileOk, $script:NotifyWatchdogListenerMisses)
            Stop-NotifyProcessGroup -ProcessIds (Merge-NotifyProcessIds -First $directListenerPids -Second $listenerRunnerPids)
            Start-NotifyScript -ScriptName 'pi-notify-restart-listener.ps1'
            $script:NotifyWatchdogListenerMisses = 0
            Start-Sleep -Seconds 3
        }

        $tunnelPids = Get-NotifyProcessIds -Pattern '*pi-notify-reverse-tunnel.ps1*'
        $sshPids = @()
        try {
            if (@($tunnelPids).Count -gt 0) {
                $sshItems = Get-CimInstance Win32_Process -ErrorAction Stop |
                    Where-Object { ($_.Name -eq 'ssh.exe') -and ($_.CommandLine -like ('*127.0.0.1:{0}:127.0.0.1:{0}*' -f $config.Port)) -and (@($tunnelPids) -contains $_.ParentProcessId) } |
                    Select-Object -ExpandProperty ProcessId
                foreach ($processId in $sshItems) {
                    if ($processId) { $sshPids += [int]$processId }
                }
            }
        }
        catch {
        }
        $duplicateTunnel = @($tunnelPids).Count -gt 1 -or @($sshPids).Count -gt 1
        $missingOwnedTunnel = @($tunnelPids).Count -ne 1 -or @($sshPids).Count -ne 1
        if (-not $tunnelOk -or $duplicateTunnel -or $missingOwnedTunnel) {
            $script:NotifyWatchdogTunnelMisses += 1
        }
        else {
            $script:NotifyWatchdogTunnelMisses = 0
        }
        if ($script:NotifyWatchdogTunnelMisses -ge 2) {
            if ($duplicateTunnel) {
                Write-NotifyWatchdogLog -Message ('duplicate-tunnel wrappers={0} ssh={1} misses={2}' -f (@($tunnelPids).Count), (@($sshPids).Count), $script:NotifyWatchdogTunnelMisses)
            }
            else {
                Write-NotifyWatchdogLog -Message ('stale-owned-tunnel wrappers={0} ssh={1} remoteTunnel={2} misses={3}' -f (@($tunnelPids).Count), (@($sshPids).Count), $tunnelOk, $script:NotifyWatchdogTunnelMisses)
            }
            Stop-NotifyProcessGroup -ProcessIds (Merge-NotifyProcessIds -First $tunnelPids -Second $sshPids) -AllowedSshParentProcessIds $tunnelPids
            Start-NotifyScript -ScriptName 'pi-notify-reverse-tunnel.ps1'
            $script:NotifyWatchdogTunnelMisses = 0
            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-NotifyWatchdogLog -Message ('watchdog-error "{0}"' -f $_.Exception.Message)
    }

    Start-Sleep -Seconds $IntervalSeconds
}
}
finally {
    Exit-NotifyWatchdogSingleton
}
