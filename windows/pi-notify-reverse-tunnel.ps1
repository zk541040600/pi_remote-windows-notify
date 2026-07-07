[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RemoteHostAlias,
    [string]$SshExecutable,
    [int]$TunnelRetryDelaySeconds,
    [int]$TunnelStartupDelaySeconds,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('RemoteHostAlias')) { $configArgs.RemoteHostAlias = $RemoteHostAlias }
if ($PSBoundParameters.ContainsKey('SshExecutable')) { $configArgs.SshExecutable = $SshExecutable }
if ($PSBoundParameters.ContainsKey('TunnelRetryDelaySeconds')) { $configArgs.TunnelRetryDelaySeconds = $TunnelRetryDelaySeconds }
if ($PSBoundParameters.ContainsKey('TunnelStartupDelaySeconds')) { $configArgs.TunnelStartupDelaySeconds = $TunnelStartupDelaySeconds }
$config = Ensure-NotifyBridgeConfig @configArgs

$ConfigPath = $config.ConfigPath
$RemoteHostAlias = $config.RemoteHostAlias
$SshExecutable = $config.SshExecutable
$TunnelRetryDelaySeconds = $config.TunnelRetryDelaySeconds
$TunnelStartupDelaySeconds = $config.TunnelStartupDelaySeconds
$forwardSpec = ('127.0.0.1:{0}:127.0.0.1:{0}' -f $config.Port)
$script:NotifyTunnelLogPath = Join-Path (Get-NotifyBridgeLogDir) 'tunnel.log'
$script:NotifyTunnelPidPath = Join-Path (Get-NotifyBridgeBaseDir) 'tunnel.pid'
$script:NotifyTunnelMutex = $null
$script:NotifyTunnelHasLock = $false
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyTunnelLogPath) | Out-Null

function Write-NotifyTunnelLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyTunnelLogPath -Value $line -Encoding UTF8
}

function Enter-NotifyTunnelSingleton {
    param([int]$Port)

    $mutexName = 'Global\PiNotifyReverseTunnel_{0}' -f $Port
    $script:NotifyTunnelMutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        $script:NotifyTunnelHasLock = $script:NotifyTunnelMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:NotifyTunnelHasLock = $true
    }

    if (-not $script:NotifyTunnelHasLock) {
        Write-NotifyTunnelLog -Message ('tunnel-singleton-exit port={0} pid={1}' -f $Port, $PID)
        exit 0
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyTunnelPidPath) | Out-Null
    Set-Content -LiteralPath $script:NotifyTunnelPidPath -Value ([string]$PID) -Encoding ASCII
}

function Exit-NotifyTunnelSingleton {
    try {
        if (Test-Path -LiteralPath $script:NotifyTunnelPidPath) {
            $current = [string](Get-Content -LiteralPath $script:NotifyTunnelPidPath -Raw -ErrorAction SilentlyContinue)
            if ($current.Trim() -eq [string]$PID) {
                Remove-Item -LiteralPath $script:NotifyTunnelPidPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
    }

    if ($script:NotifyTunnelHasLock -and $null -ne $script:NotifyTunnelMutex) {
        try { $script:NotifyTunnelMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:NotifyTunnelMutex) {
        $script:NotifyTunnelMutex.Dispose()
    }
}

Enter-NotifyTunnelSingleton -Port ([int]$config.Port)

try {
Write-NotifyTunnelLog -Message ('tunnel-start pid={0} ssh="{1}" forward="{2}" remote="{3}" startupDelay={4}s retry={5}s' -f $PID, $SshExecutable, $forwardSpec, $RemoteHostAlias, $TunnelStartupDelaySeconds, $TunnelRetryDelaySeconds)
if ($TunnelStartupDelaySeconds -gt 0) {
    Start-Sleep -Seconds $TunnelStartupDelaySeconds
}

while ($true) {
    Write-NotifyTunnelLog -Message ('tunnel-attempt forward="{0}" remote="{1}"' -f $forwardSpec, $RemoteHostAlias)
    Write-Host ('[{0}] starting reverse tunnel: {1} -> {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $forwardSpec, $RemoteHostAlias)

    $arguments = @(
        '-N',
        '-T',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'TCPKeepAlive=yes',
        '-R', $forwardSpec,
        $RemoteHostAlias
    )

    & $SshExecutable @arguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-NotifyTunnelLog -Message 'tunnel-exit code=0 clean'
        Write-Host ('[{0}] reverse tunnel exited cleanly.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    }
    else {
        Write-NotifyTunnelLog -Message ('tunnel-exit code={0} retry={1}s' -f $exitCode, $TunnelRetryDelaySeconds)
        Write-Warning ('Reverse tunnel exited with code {0}. Retrying in {1}s.' -f $exitCode, $TunnelRetryDelaySeconds)
    }

    if ($Once) {
        break
    }

    Start-Sleep -Seconds $TunnelRetryDelaySeconds
}
}
finally {
    Exit-NotifyTunnelSingleton
}
