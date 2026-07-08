[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RemoteHostAlias,
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$SshExecutable,
    [int]$TunnelRetryDelaySeconds,
    [int]$TunnelStartupDelaySeconds,
    [ValidateSet('cursor', 'primary', 'right')]
    [string]$PopupPlacement,
    [switch]$StartNow = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

function New-VbsLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExe,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPathValue
    )

    $command = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}"' -f $PowerShellExe, $ScriptPath, $ConfigPathValue)
    $escapedCommand = $command.Replace('"', '""')
    $content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escapedCommand", 0, False
"@
    $content = $content.TrimStart()
    if (Test-Path -LiteralPath $FilePath) {
        $existing = Get-Content -LiteralPath $FilePath -Raw -ErrorAction SilentlyContinue
        if ($existing -eq $content -or $existing -eq ($content + "`r`n") -or $existing -eq ($content + "`n")) {
            return
        }
    }
    $tempPath = ('{0}.tmp.{1}' -f $FilePath, $PID)
    [System.IO.File]::WriteAllText($tempPath, $content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $FilePath -Force
}

function Remove-LegacyScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host ('Removed legacy scheduled task: {0}' -f $TaskName)
            return
        }
    }
    catch {
    }

    try {
        & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ('Removed legacy scheduled task: {0}' -f $TaskName)
        }
    }
    catch {
    }
}

function Register-NotifyBridgeProtocol {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExe,
        [Parameter(Mandatory = $true)]
        [string]$ActivationScript,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPathValue
    )

    $protocolName = Get-NotifyBridgeProtocolName
    $protocolRoot = ('Registry::HKEY_CURRENT_USER\Software\Classes\{0}' -f $protocolName)
    $commandKey = Join-Path $protocolRoot 'shell\open\command'
    $commandValue = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" "%1"' -f $PowerShellExe, $ActivationScript, $ConfigPathValue)

    New-Item -Path $protocolRoot -Force | Out-Null
    Set-Item -Path $protocolRoot -Value ('URL:{0} Protocol' -f $protocolName)
    New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -Path $commandKey -Value $commandValue

    return ('{0}://focus' -f $protocolName)
}

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('RemoteHostAlias')) { $configArgs.RemoteHostAlias = $RemoteHostAlias }
if ($PSBoundParameters.ContainsKey('ListenHost')) { $configArgs.ListenHost = $ListenHost }
if ($PSBoundParameters.ContainsKey('Port')) { $configArgs.Port = $Port }
if ($PSBoundParameters.ContainsKey('Token')) { $configArgs.Token = $Token }
if ($PSBoundParameters.ContainsKey('SshExecutable')) { $configArgs.SshExecutable = $SshExecutable }
if ($PSBoundParameters.ContainsKey('TunnelRetryDelaySeconds')) { $configArgs.TunnelRetryDelaySeconds = $TunnelRetryDelaySeconds }
if ($PSBoundParameters.ContainsKey('TunnelStartupDelaySeconds')) { $configArgs.TunnelStartupDelaySeconds = $TunnelStartupDelaySeconds }
if ($PSBoundParameters.ContainsKey('PopupPlacement')) { $configArgs.PopupPlacement = $PopupPlacement }
$config = Ensure-NotifyBridgeConfig @configArgs

$baseDir = Get-NotifyBridgeBaseDir
$binDir = Get-NotifyBridgeBinDir
$logDir = Get-NotifyBridgeLogDir
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$null = New-Item -ItemType Directory -Force -Path $baseDir, $binDir, $logDir, $startupDir

$filesToCopy = @(
    'NotifyBridge.Common.ps1',
    'notify-listener.ps1',
    'pi-notify-reverse-tunnel.ps1',
    'pi-notify-activate.ps1',
    'pi-notify-hotkey.ps1',
    'pi-notify-popup.ps1',
    'pi-notify-broker.ps1',
    'pi-notify-watchdog.ps1',
    'pi-notify-listener-runner.ps1',
    'pi-notify-restart-listener.ps1',
    'pi-notify-refresh.ps1',
    'pi-notify-check.ps1',
    'pi-notify-noop.ps1',
    'register-toast-shortcut.py',
    'set-notify-mode.ps1',
    'remote-windows-notify.ts',
    'popup-wallpaper.png',
    'install-remote-windows-notify.ps1',
    'install-linux-autostart.ps1',
    'install-windows-autostart.ps1',
    'install-autostart-all.ps1'
)
foreach ($name in $filesToCopy) {
    $source = Join-Path $PSScriptRoot $name
    $destination = Join-Path $binDir $name
    if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

$listenerScript = Join-Path $binDir 'pi-notify-restart-listener.ps1'
$tunnelScript = Join-Path $binDir 'pi-notify-reverse-tunnel.ps1'
$hotkeyScript = Join-Path $binDir 'pi-notify-hotkey.ps1'
$activationScript = Join-Path $binDir 'pi-notify-activate.ps1'
$brokerScript = Join-Path $binDir 'pi-notify-broker.ps1'
$powershellExe = Get-NotifyBridgePowerShellExe
$toastSupport = Register-NotifyBridgeSystemToastSupport -ConfigPathValue $config.ConfigPath -ToastAppId 'Pi Remote'
$protocolUri = $toastSupport.ProtocolUri
$toastShortcutPath = $toastSupport.ShortcutPath
$popupHotkeyShortcutPath = Register-NotifyBridgePopupHotkeyShortcut -PowerShellExe $powershellExe -HotkeyScript $hotkeyScript -ConfigPathValue $config.ConfigPath -HotkeyValue $config.PopupHotkey -Enabled ([bool]$config.PopupHotkeyEnabled)
$installMode = ''

$listenerVbs = Join-Path $startupDir 'PiNotifyListener.vbs'
$tunnelVbs = Join-Path $startupDir 'PiNotifyTunnel.vbs'
$watchdogVbs = Join-Path $startupDir 'PiNotifyWatchdog.vbs'
$brokerVbs = Join-Path $startupDir 'PiNotifyBroker.vbs'
$hotkeyVbs = Join-Path $startupDir 'PiNotifyHotkey.vbs'
Remove-Item -LiteralPath $hotkeyVbs -Force -ErrorAction SilentlyContinue

foreach ($taskName in @('PiNotifyListener', 'PiNotifyTunnel', 'PiNotifyWatchdog', 'PiNotifyHotkey', 'PiNotifyBroker')) {
    Remove-LegacyScheduledTask -TaskName $taskName
}

$installMode = 'StartupFolder'
$watchdogScript = Join-Path $binDir 'pi-notify-watchdog.ps1'
New-VbsLauncher -FilePath $listenerVbs -PowerShellExe $powershellExe -ScriptPath $listenerScript -ConfigPathValue $config.ConfigPath
New-VbsLauncher -FilePath $tunnelVbs -PowerShellExe $powershellExe -ScriptPath $tunnelScript -ConfigPathValue $config.ConfigPath
New-VbsLauncher -FilePath $watchdogVbs -PowerShellExe $powershellExe -ScriptPath $watchdogScript -ConfigPathValue $config.ConfigPath

# Broker needs -STA for the WinForms message loop; write a dedicated VBS launcher
$brokerCommand = ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}"' -f $powershellExe, $brokerScript, $config.ConfigPath)
$brokerEscaped = $brokerCommand.Replace('"', '""')
$brokerContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$brokerEscaped", 0, False
"@
$brokerContent = $brokerContent.TrimStart()
if (Test-Path -LiteralPath $brokerVbs) {
    $existingBroker = Get-Content -LiteralPath $brokerVbs -Raw -ErrorAction SilentlyContinue
    if ($existingBroker -ne $brokerContent -and $existingBroker -ne ($brokerContent + "`r`n") -and $existingBroker -ne ($brokerContent + "`n")) {
        $brokerTemp = ('{0}.tmp.{1}' -f $brokerVbs, $PID)
        [System.IO.File]::WriteAllText($brokerTemp, $brokerContent, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $brokerTemp -Destination $brokerVbs -Force
    }
}
else {
    [System.IO.File]::WriteAllText($brokerVbs, $brokerContent, [System.Text.UTF8Encoding]::new($false))
}

if ($StartNow) {
    & wscript.exe $listenerVbs | Out-Null
    Start-Sleep -Seconds 2
    & wscript.exe $brokerVbs | Out-Null
    Start-Sleep -Seconds 1
    & wscript.exe $tunnelVbs | Out-Null
    Start-Sleep -Seconds 2
    & wscript.exe $watchdogVbs | Out-Null
}

Write-Host 'Windows Pi notify auto-start installed.'
Write-Host ('Mode         : {0}' -f $installMode)
Write-Host ('Config       : {0}' -f $config.ConfigPath)
Write-Host ('Remote host  : {0}' -f $config.RemoteHostAlias)
Write-Host ('SSH exe      : {0}' -f $config.SshExecutable)
Write-Host ('Bin dir      : {0}' -f $binDir)
Write-Host ('Click URI    : {0}' -f $protocolUri)
Write-Host ('Toast link   : {0}' -f $toastShortcutPath)
Write-Host ('Listener VBS : {0}' -f $listenerVbs)
Write-Host ('Tunnel VBS   : {0}' -f $tunnelVbs)
Write-Host ('Broker VBS   : {0}' -f $brokerVbs)
Write-Host ('Watchdog VBS : {0}' -f $watchdogVbs)
Write-Host ('Hotkey link  : {0}' -f $popupHotkeyShortcutPath)
Write-Host ('Popup hotkey : {0}' -f $config.PopupHotkey)
