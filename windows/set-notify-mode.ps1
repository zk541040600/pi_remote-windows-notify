[CmdletBinding()]
param(
    [ValidateSet('system-toast', 'popup-focus')]
    [string]$Mode,
    [string]$ConfigPath,
    [int]$PopupTimeoutSeconds,
    [ValidateSet('cursor', 'primary', 'right')]
    [string]$PopupPlacement,
    [switch]$RestartListener = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('Mode')) { $configArgs.DisplayMode = $Mode }
if ($PSBoundParameters.ContainsKey('PopupTimeoutSeconds')) { $configArgs.PopupTimeoutSeconds = $PopupTimeoutSeconds }
if ($PSBoundParameters.ContainsKey('PopupPlacement')) { $configArgs.PopupPlacement = $PopupPlacement }
$config = Ensure-NotifyBridgeConfig @configArgs

$binDir = Get-NotifyBridgeBinDir
if ($config.DisplayMode -eq 'system-toast') {
    Register-NotifyBridgeSystemToastSupport -ConfigPathValue $config.ConfigPath -ToastAppId 'Pi Remote' | Out-Null
}

if ($RestartListener) {
    $restartScript = Join-Path $binDir 'pi-notify-restart-listener.ps1'
    if (-not (Test-Path -LiteralPath $restartScript)) {
        $restartScript = Join-Path $PSScriptRoot 'pi-notify-restart-listener.ps1'
    }
    & $restartScript -ConfigPath $config.ConfigPath
}

Write-Host ('Notify mode     : {0}' -f $config.DisplayMode)
Write-Host ('Popup timeout   : {0}' -f $config.PopupTimeoutSeconds)
Write-Host ('Popup placement : {0}' -f $config.PopupPlacement)
Write-Host ('Config path     : {0}' -f $config.ConfigPath)
Write-Host ('Listener restart: {0}' -f $RestartListener)
