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
python - <<'PY'
import urllib.request
with urllib.request.urlopen('http://127.0.0.1:$($config.Port)/health', timeout=4) as r:
    print('HTTP', r.status)
PY
"@
    try {
        $output = & $config.SshExecutable -o BatchMode=yes $config.RemoteHostAlias $probe 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Get-NotifyProcessIds {
    param([string]$Pattern)
    $pids = @()
    try {
        $items = Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.CommandLine -like $Pattern } |
            Select-Object -ExpandProperty ProcessId
        foreach ($pid in $items) {
            if ($pid) { $pids += [int]$pid }
        }
    }
    catch {
    }
    return @($pids | Select-Object -Unique)
}

function Stop-NotifyProcessGroup {
    param([int[]]$ProcessIds)
    foreach ($pid in @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        try {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $pid, '/F', '/T') -WindowStyle Hidden -Wait | Out-Null
            Write-NotifyWatchdogLog -Message ('taskkill pid={0}' -f $pid)
        }
        catch {
        }
    }
}

function Start-NotifyScript {
    param([string]$ScriptName)
    $scriptPath = Join-Path (Get-NotifyBridgeBinDir) $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-NotifyWatchdogLog -Message ('missing-script "{0}"' -f $scriptPath)
        return
    }
    Start-Process -FilePath (Get-NotifyBridgePowerShellExe) -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-ConfigPath', $config.ConfigPath
    ) | Out-Null
    Write-NotifyWatchdogLog -Message ('start-script {0}' -f $ScriptName)
}

Write-NotifyWatchdogLog -Message ('watchdog-start startupDelay={0}s interval={1}s' -f $StartupDelaySeconds, $IntervalSeconds)
if ($StartupDelaySeconds -gt 0) {
    Start-Sleep -Seconds $StartupDelaySeconds
}

while ($true) {
    try {
        $listenerOk = Test-NotifyListenerHealth
        $tunnelOk = Test-NotifyRemoteTunnel
        Write-NotifyWatchdogLog -Message ('health listener={0} tunnel={1}' -f $listenerOk, $tunnelOk)

        if (-not $listenerOk) {
            Stop-NotifyProcessGroup -ProcessIds (Get-NotifyProcessIds -Pattern '*notify-listener.ps1*')
            Start-NotifyScript -ScriptName 'notify-listener.ps1'
            Start-Sleep -Seconds 3
        }

        if (-not $tunnelOk) {
            $tunnelPids = Get-NotifyProcessIds -Pattern '*pi-notify-reverse-tunnel.ps1*'
            $sshPids = @()
            try {
                $sshItems = Get-CimInstance Win32_Process -ErrorAction Stop |
                    Where-Object { ($_.Name -eq 'ssh.exe') -and ($_.CommandLine -like ('*127.0.0.1:{0}:127.0.0.1:{0}*' -f $config.Port)) } |
                    Select-Object -ExpandProperty ProcessId
                foreach ($pid in $sshItems) {
                    if ($pid) { $sshPids += [int]$pid }
                }
            }
            catch {
            }
            Stop-NotifyProcessGroup -ProcessIds ($tunnelPids + $sshPids)
            Start-NotifyScript -ScriptName 'pi-notify-reverse-tunnel.ps1'
            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-NotifyWatchdogLog -Message ('watchdog-error "{0}"' -f $_.Exception.Message)
    }

    Start-Sleep -Seconds $IntervalSeconds
}
