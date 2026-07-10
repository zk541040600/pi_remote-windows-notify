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

$remotePiDir = Resolve-NotifyBridgeRemotePiDir -PathValue $RemotePiDir -RemoteHome $remoteHome
$remoteExtensionDir = "$remotePiDir/extensions"
$remoteExtensionPath = "$remoteExtensionDir/remote-windows-notify.ts"
$remoteManagedDir = "$remoteHome/.local/share/pi-notify"
$remoteManagedExtensionPath = "$remoteManagedDir/remote-windows-notify.ts"
$remoteManagedConfigPath = "$remoteManagedDir/remote-windows-notify.json"
$remoteConfigPath = "$remotePiDir/remote-windows-notify.json"

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
$mkdirCommand = ('mkdir -p {0} {1}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteExtensionDir), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir))
& $sshExe @sshOptions $RemoteHostAlias $mkdirCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create remote extension directories on $RemoteHostAlias."
}

Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $templatePath -RemotePath $remoteExtensionPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote extension to $RemoteHostAlias."
}

Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $templatePath -RemotePath $remoteManagedExtensionPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote extension to $RemoteHostAlias."
}

$syncCommand = ('REMOTE_MANAGED_EXT={0} REMOTE_PI_DIR={1} python3 -' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedExtensionPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remotePiDir))
@'
import os
import shutil

src = os.environ["REMOTE_MANAGED_EXT"]
remote_pi_dir = os.environ["REMOTE_PI_DIR"]
roots = [
    os.path.join(os.path.expanduser("~"), ".pi", "agent", "git", "github.com", "zk541040600", "pi_remote-windows-notify"),
    os.path.join(remote_pi_dir, "git", "github.com", "zk541040600", "pi_remote-windows-notify"),
]
for root in dict.fromkeys(roots):
    if not (os.path.isfile(src) and os.path.isdir(root)):
        continue
    for dirpath, _dirnames, filenames in os.walk(root):
        if "remote-windows-notify.ts" not in filenames:
            continue
        dest = os.path.join(dirpath, "remote-windows-notify.ts")
        shutil.copyfile(src, dest)
        os.chmod(dest, 0o644)
        print(f"synced package extension: {dest}")
'@ | & $sshExe @sshOptions $RemoteHostAlias $syncCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to sync remote package extension copies on $RemoteHostAlias."
}

Copy-NotifyBridgeTextToRemotePath @remoteTransferArgs -Content $remoteConfigJson -RemotePath $remoteConfigPath -Mode '0600'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote config to $RemoteHostAlias."
}

Copy-NotifyBridgeTextToRemotePath @remoteTransferArgs -Content $remoteConfigJson -RemotePath $remoteManagedConfigPath -Mode '0600'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote config to $RemoteHostAlias."
}

$verifyCommand = ('test -f {0} && test -f {1} && test -f {2} && test "$(stat -c ''%a'' {1})" = 600 && test "$(stat -c ''%a'' {2})" = 600 && printf ''REMOTE_INSTALLED=1\nEXT=%s\nCFG=%s\nMANAGED_CFG=%s\n'' {3} {4} {5}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteExtensionPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteConfigPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedConfigPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteExtensionPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteConfigPath), (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedConfigPath))
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
