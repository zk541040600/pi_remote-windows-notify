[CmdletBinding()]
param(
    [string]$RemoteHostAlias = 'my',
    [string]$RemotePiDir = '~/.pi/agent',
    [string]$ConfigPath,
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$SshExecutable,
    [int]$TunnelRetryDelaySeconds,
    [int]$TunnelStartupDelaySeconds,
    [ValidateSet('cursor', 'primary', 'right')]
    [string]$PopupPlacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $commonArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('RemoteHostAlias')) { $commonArgs.RemoteHostAlias = $RemoteHostAlias }
if ($PSBoundParameters.ContainsKey('ListenHost')) { $commonArgs.ListenHost = $ListenHost }
if ($PSBoundParameters.ContainsKey('Port')) { $commonArgs.Port = $Port }
if ($PSBoundParameters.ContainsKey('Token')) { $commonArgs.Token = $Token }
if ($PSBoundParameters.ContainsKey('SshExecutable')) { $commonArgs.SshExecutable = $SshExecutable }
if ($PSBoundParameters.ContainsKey('TunnelRetryDelaySeconds')) { $commonArgs.TunnelRetryDelaySeconds = $TunnelRetryDelaySeconds }
if ($PSBoundParameters.ContainsKey('TunnelStartupDelaySeconds')) { $commonArgs.TunnelStartupDelaySeconds = $TunnelStartupDelaySeconds }
if ($PSBoundParameters.ContainsKey('PopupPlacement')) { $commonArgs.PopupPlacement = $PopupPlacement }

& (Join-Path $PSScriptRoot 'install-windows-autostart.ps1') @commonArgs
$linuxArgs = @{} + $commonArgs
$linuxArgs.RemotePiDir = $RemotePiDir
& (Join-Path $PSScriptRoot 'install-linux-autostart.ps1') @linuxArgs

Write-Host 'Pi notify auto-start installed on both Windows and Linux.'
