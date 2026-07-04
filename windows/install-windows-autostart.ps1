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
    [System.IO.File]::WriteAllText($FilePath, $content.TrimStart(), [System.Text.UTF8Encoding]::new($false))
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
    $protocolRoot = ('HKCU\Software\Classes\{0}' -f $protocolName)
    $commandKey = ('{0}\shell\open\command' -f $protocolRoot)
    $commandValue = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" "%1"' -f $PowerShellExe, $ActivationScript, $ConfigPathValue)

    & reg.exe add $protocolRoot /ve /d ('URL:{0} Protocol' -f $protocolName) /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to register protocol root.' }

    & reg.exe add $protocolRoot /v 'URL Protocol' /d '' /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to register URL Protocol marker.' }

    & reg.exe add $commandKey /ve /d $commandValue /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to register protocol open command.' }

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
    'pi-notify-popup.ps1',
    'pi-notify-watchdog.ps1',
    'pi-notify-noop.ps1',
    'register-toast-shortcut.py',
    'set-notify-mode.ps1'
)
foreach ($name in $filesToCopy) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $binDir $name) -Force
}

$listenerScript = Join-Path $binDir 'notify-listener.ps1'
$tunnelScript = Join-Path $binDir 'pi-notify-reverse-tunnel.ps1'
$activationScript = Join-Path $binDir 'pi-notify-activate.ps1'
$noopScript = Join-Path $binDir 'pi-notify-noop.ps1'
$registerShortcutScript = Join-Path $binDir 'register-toast-shortcut.py'
$powershellExe = Get-NotifyBridgePowerShellExe
$protocolUri = Register-NotifyBridgeProtocol -PowerShellExe $powershellExe -ActivationScript $activationScript -ConfigPathValue $config.ConfigPath
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$installMode = ''

$toastShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Pi Remote.lnk'
$shortcutArgs = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $noopScript)
$shortcutIcon = ('{0},0' -f $powershellExe)
$pythonExe = Resolve-NotifyBridgePythonExecutable
if ($pythonExe) {
    try {
        & $pythonExe $registerShortcutScript --shortcut $toastShortcutPath --target $powershellExe --arguments $shortcutArgs --workdir $baseDir --icon $shortcutIcon --app-id 'Pi Remote' | Out-Null
    }
    catch {
        Write-Warning ('Toast shortcut registration failed: {0}' -f $_.Exception.Message)
    }
}
else {
    Write-Warning 'Python was not found; Windows native toast AppID shortcut was not registered. popup-focus mode is unaffected.'
}

$listenerTaskName = 'PiNotifyListener'
$tunnelTaskName = 'PiNotifyTunnel'
$watchdogTaskName = 'PiNotifyWatchdog'
$listenerVbs = Join-Path $startupDir 'PiNotifyListener.vbs'
$tunnelVbs = Join-Path $startupDir 'PiNotifyTunnel.vbs'
$watchdogVbs = Join-Path $startupDir 'PiNotifyWatchdog.vbs'

$taskError = $null
try {
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    $watchdogScript = Join-Path $binDir 'pi-notify-watchdog.ps1'
    $listenerAction = New-ScheduledTaskAction -Execute $powershellExe -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $listenerScript, $config.ConfigPath)
    $tunnelAction = New-ScheduledTaskAction -Execute $powershellExe -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $tunnelScript, $config.ConfigPath)
    $watchdogAction = New-ScheduledTaskAction -Execute $powershellExe -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $watchdogScript, $config.ConfigPath)

    $listenerTask = New-ScheduledTask -Action $listenerAction -Trigger $trigger -Settings $settings -Principal $principal -Description 'Pi notify listener auto-starts at user logon.'
    $tunnelTask = New-ScheduledTask -Action $tunnelAction -Trigger $trigger -Settings $settings -Principal $principal -Description 'Pi notify reverse SSH tunnel auto-starts and auto-reconnects at user logon.'
    $watchdogTask = New-ScheduledTask -Action $watchdogAction -Trigger $trigger -Settings $settings -Principal $principal -Description 'Pi notify watchdog restarts listener/tunnel when health checks fail.'

    foreach ($taskName in @($listenerTaskName, $tunnelTaskName, $watchdogTaskName)) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        }
        catch {
        }
    }

    Register-ScheduledTask -TaskName $listenerTaskName -InputObject $listenerTask | Out-Null
    Register-ScheduledTask -TaskName $tunnelTaskName -InputObject $tunnelTask | Out-Null
    Register-ScheduledTask -TaskName $watchdogTaskName -InputObject $watchdogTask | Out-Null
    $installMode = 'ScheduledTask'

    if (Test-Path -LiteralPath $listenerVbs) { Remove-Item -LiteralPath $listenerVbs -Force }
    if (Test-Path -LiteralPath $tunnelVbs) { Remove-Item -LiteralPath $tunnelVbs -Force }
    if (Test-Path -LiteralPath $watchdogVbs) { Remove-Item -LiteralPath $watchdogVbs -Force }

    if ($StartNow) {
        foreach ($taskName in @($listenerTaskName, $tunnelTaskName, $watchdogTaskName)) {
            try {
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            }
            catch {
                Write-Warning ('Failed to start scheduled task {0}: {1}' -f $taskName, $_.Exception.Message)
            }
            Start-Sleep -Seconds 2
        }
    }
}
catch {
    $taskError = $_
    $installMode = 'StartupFolder'

    $watchdogScript = Join-Path $binDir 'pi-notify-watchdog.ps1'
    New-VbsLauncher -FilePath $listenerVbs -PowerShellExe $powershellExe -ScriptPath $listenerScript -ConfigPathValue $config.ConfigPath
    New-VbsLauncher -FilePath $tunnelVbs -PowerShellExe $powershellExe -ScriptPath $tunnelScript -ConfigPathValue $config.ConfigPath
    New-VbsLauncher -FilePath $watchdogVbs -PowerShellExe $powershellExe -ScriptPath $watchdogScript -ConfigPathValue $config.ConfigPath

    if ($StartNow) {
        & wscript.exe $listenerVbs | Out-Null
        Start-Sleep -Seconds 2
        & wscript.exe $tunnelVbs | Out-Null
        Start-Sleep -Seconds 2
        & wscript.exe $watchdogVbs | Out-Null
    }
}

Write-Host 'Windows Pi notify auto-start installed.'
Write-Host ('Mode         : {0}' -f $installMode)
Write-Host ('Config       : {0}' -f $config.ConfigPath)
Write-Host ('Remote host  : {0}' -f $config.RemoteHostAlias)
Write-Host ('SSH exe      : {0}' -f $config.SshExecutable)
Write-Host ('Bin dir      : {0}' -f $binDir)
Write-Host ('Click URI    : {0}' -f $protocolUri)
if ($installMode -eq 'ScheduledTask') {
    Write-Host ('Listener task: {0}' -f $listenerTaskName)
    Write-Host ('Tunnel task  : {0}' -f $tunnelTaskName)
}
else {
    Write-Host ('Listener VBS : {0}' -f $listenerVbs)
    Write-Host ('Tunnel VBS   : {0}' -f $tunnelVbs)
    Write-Host ('Watchdog VBS : {0}' -f $watchdogVbs)
    if ($null -ne $taskError) {
        Write-Warning ('Scheduled task registration failed, fell back to Startup folder: {0}' -f $taskError.Exception.Message)
    }
}
