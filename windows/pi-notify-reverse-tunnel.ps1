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
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyTunnelLogPath) | Out-Null

function Write-NotifyTunnelLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyTunnelLogPath -Value $line -Encoding UTF8
}

Write-NotifyTunnelLog -Message ('tunnel-start ssh="{0}" forward="{1}" remote="{2}" startupDelay={3}s retry={4}s' -f $SshExecutable, $forwardSpec, $RemoteHostAlias, $TunnelStartupDelaySeconds, $TunnelRetryDelaySeconds)
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
