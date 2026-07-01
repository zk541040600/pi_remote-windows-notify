[CmdletBinding()]
param(
    [ValidateSet('system-toast', 'popup-focus')]
    [string]$Mode,
    [string]$ConfigPath,
    [int]$PopupTimeoutSeconds,
    [switch]$RestartListener = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('Mode')) { $configArgs.DisplayMode = $Mode }
if ($PSBoundParameters.ContainsKey('PopupTimeoutSeconds')) { $configArgs.PopupTimeoutSeconds = $PopupTimeoutSeconds }
$config = Ensure-NotifyBridgeConfig @configArgs

if ($RestartListener) {
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*notify-listener.ps1*' } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
    }
    catch {
    }

    Start-Sleep -Seconds 2
    $binDir = Get-NotifyBridgeBinDir
    $listenerScript = Join-Path $binDir 'notify-listener.ps1'
    if (-not (Test-Path -LiteralPath $listenerScript)) {
        $listenerScript = Join-Path $PSScriptRoot 'notify-listener.ps1'
    }

    if ($config.DisplayMode -eq 'system-toast') {
        $registerShortcutScript = Join-Path $binDir 'register-toast-shortcut.py'
        $noopScript = Join-Path $binDir 'pi-notify-noop.ps1'
        $shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Pi Remote.lnk'
        if ((Test-Path -LiteralPath $registerShortcutScript) -and (Test-Path -LiteralPath $noopScript)) {
            $shortcutArgs = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $noopScript)
            $shortcutIcon = ('{0},0' -f (Get-NotifyBridgePowerShellExe))
            try {
                & python $registerShortcutScript --shortcut $shortcutPath --target (Get-NotifyBridgePowerShellExe) --arguments $shortcutArgs --workdir (Get-NotifyBridgeBaseDir) --icon $shortcutIcon --app-id 'Pi Remote' | Out-Null
            }
            catch {
            }
        }
    }

    Start-Process -FilePath (Get-NotifyBridgePowerShellExe) -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $listenerScript,
        '-ConfigPath', $config.ConfigPath
    ) | Out-Null
}

Write-Host ('Notify mode     : {0}' -f $config.DisplayMode)
Write-Host ('Popup timeout   : {0}' -f $config.PopupTimeoutSeconds)
Write-Host ('Config path     : {0}' -f $config.ConfigPath)
Write-Host ('Listener restart: {0}' -f $RestartListener)
