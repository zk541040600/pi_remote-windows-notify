[CmdletBinding()]
param(
    [string]$RemoteHostAlias = "my",
    [string]$RemotePiDir = "~/.pi/agent",
    [string]$ConfigPath,
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$SshExecutable,
    [ValidateSet('cursor', 'primary', 'right')]
    [string]$PopupPlacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/NotifyBridge.Remote.ps1"

$configArgs = @{}
$staleTokenTempFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'remote-windows-notify.*.json' -ErrorAction SilentlyContinue)
foreach ($staleTokenTempFile in $staleTokenTempFiles) {
    Remove-Item -LiteralPath $staleTokenTempFile.FullName -Force -ErrorAction SilentlyContinue
}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('RemoteHostAlias')) { $configArgs.RemoteHostAlias = $RemoteHostAlias }
if ($PSBoundParameters.ContainsKey('ListenHost')) { $configArgs.ListenHost = $ListenHost }
if ($PSBoundParameters.ContainsKey('Port')) { $configArgs.Port = $Port }
if ($PSBoundParameters.ContainsKey('Token')) { $configArgs.Token = $Token }
if ($PSBoundParameters.ContainsKey('SshExecutable')) { $configArgs.SshExecutable = $SshExecutable }
if ($PSBoundParameters.ContainsKey('PopupPlacement')) { $configArgs.PopupPlacement = $PopupPlacement }
$config = Ensure-NotifyBridgeConfig @configArgs
$baseDir = Get-NotifyBridgeBaseDir
$binDir = Get-NotifyBridgeBinDir
$logDir = Get-NotifyBridgeLogDir
New-Item -ItemType Directory -Force -Path $baseDir, $binDir, $logDir | Out-Null
$runtimeFiles = @(
    'NotifyBridge.Common.ps1',
    'NotifyBridge.Process.ps1',
    'NotifyBridge.Remote.ps1',
    'notify-listener.ps1',
    'pi-notify-listener-runner.ps1',
    'pi-notify-restart-listener.ps1',
    'pi-notify-popup.ps1',
    'pi-notify-broker.ps1',
    'pi-notify-activate.ps1',
    'pi-notify-hotkey.ps1',
    'pi-notify-reverse-tunnel.ps1',
    'pi-notify-watchdog.ps1',
    'pi-notify-refresh.ps1',
    'pi-notify-check.ps1',
    'pi-notify-noop.ps1',
    'register-toast-shortcut.py',
    'set-notify-mode.ps1',
    'pi-notify-ensure.mjs',
    'remote-windows-notify.ts',
    'popup-wallpaper.png',
    'install-remote-windows-notify.ps1',
    'install-linux-autostart.ps1',
    'install-windows-autostart.ps1',
    'install-autostart-all.ps1'
)
foreach ($name in $runtimeFiles) {
    $source = Join-Path $PSScriptRoot $name
    $destination = Join-Path $binDir $name
    if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
$toastSupport = Register-NotifyBridgeSystemToastSupport -ConfigPathValue $config.ConfigPath -ToastAppId 'Pi Remote'
$preferredSshExe = [string]$config.SshExecutable
$sshOptions = @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
$templatePath = Join-Path $PSScriptRoot 'remote-windows-notify.ts'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Extension template not found: $templatePath"
}
$ensurePath = Join-Path $PSScriptRoot 'pi-notify-ensure.mjs'
if (-not (Test-Path -LiteralPath $ensurePath)) {
    throw "Remote ensure program not found: $ensurePath"
}

$sshExe = Resolve-NotifyBridgeWorkingSshExecutable -PreferredSshExe $preferredSshExe -RemoteHost $RemoteHostAlias -SshOptions $sshOptions
if ($sshExe -ne [string]$config.SshExecutable) {
    $config = Ensure-NotifyBridgeConfig -ConfigPath $config.ConfigPath -SshExecutable $sshExe
}
$remoteTransferArgs = @{
    SshExecutable = $sshExe
    SshOptions    = $sshOptions
    RemoteHost   = $RemoteHostAlias
}
$remoteHome = (& $sshExe @sshOptions $RemoteHostAlias 'printf %s "$HOME"').Trim()
if ([string]::IsNullOrWhiteSpace($remoteHome)) {
    throw "Failed to resolve remote HOME on $RemoteHostAlias."
}
$remoteNode = (& $sshExe @sshOptions $RemoteHostAlias 'command -v node').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteNode)) {
    throw "Failed to resolve remote Node.js on $RemoteHostAlias."
}

$remotePiDir = Resolve-NotifyBridgeRemotePiDir -PathValue $RemotePiDir -RemoteHome $remoteHome
$remoteManagedDir = "$remoteHome/.local/share/pi-notify"
$remoteManagedExtensionPath = "$remoteManagedDir/remote-windows-notify.ts"
$remoteManagedEnsurePath = "$remoteManagedDir/pi-notify-ensure.mjs"
$remoteManagedConfigPath = "$remoteManagedDir/remote-windows-notify.json"

$remoteConfig = @{
    enabled         = $true
    endpoint        = $config.RemoteUrl
    token           = $config.Token
    timeoutMs       = 4000
    title           = 'Pi'
    bodyTemplate    = 'host: {host} | cwd: {cwdBase}'
    messageMode     = 'dynamic'
    remoteHostAlias = $RemoteHostAlias
}
$remoteConfigJson = $remoteConfig | ConvertTo-Json -Depth 6

Write-Host "Installing remote Pi notify bridge on $RemoteHostAlias ..."
$mkdirCommand = ('mkdir -p {0}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir))
& $sshExe @sshOptions $RemoteHostAlias $mkdirCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create remote managed directory on $RemoteHostAlias."
}

Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $templatePath -RemotePath $remoteManagedExtensionPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote extension to $RemoteHostAlias."
}

Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $ensurePath -RemotePath $remoteManagedEnsurePath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote ensure program to $RemoteHostAlias."
}

Copy-NotifyBridgeTextToRemotePath @remoteTransferArgs -Content $remoteConfigJson -RemotePath $remoteManagedConfigPath -Mode '0600'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote config to $RemoteHostAlias."
}

$ensureCommand = ('{0} {1} --managed-dir {2} --pi-dir {3}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteNode), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedEnsurePath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remotePiDir))
& $sshExe @sshOptions $RemoteHostAlias $ensureCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to converge remote extension ownership on $RemoteHostAlias."
}

$verifyCommand = ('{0} {1} --check --managed-dir {2}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteNode), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedEnsurePath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir))
& $sshExe @sshOptions $RemoteHostAlias $verifyCommand
if ($LASTEXITCODE -ne 0) {
    throw "Remote verify failed on $RemoteHostAlias."
}

Write-Host ""
Write-Host "Installed successfully."
Write-Host "Local listener config : $($config.ConfigPath)"
Write-Host "Local listener URL    : $($config.LocalUrl)"
Write-Host "Remote tunnel URL     : $($config.RemoteUrl)"
Write-Host "Remote Pi dir        : $remotePiDir"
Write-Host "Click URI            : $($toastSupport.ProtocolUri)"
Write-Host "Toast link           : $($toastSupport.ShortcutPath)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Start local listener:"
Write-Host ('   powershell.exe -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'pi-notify-restart-listener.ps1'))
Write-Host ('   # or from the runtime bin: powershell.exe -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $binDir 'pi-notify-restart-listener.ps1'))
Write-Host "2. Connect with reverse tunnel:"
Write-Host "   ssh -R 127.0.0.1:$($config.Port):127.0.0.1:$($config.Port) $RemoteHostAlias"
Write-Host "3. In Pi on $RemoteHostAlias, run /reload if it is already open."
