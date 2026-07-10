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

. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/NotifyBridge.Remote.ps1"

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
$preferredSshExe = [string]$config.SshExecutable
$sshOptions = @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

function ConvertTo-SingleQuotedShellContent {
    param([Parameter(Mandatory = $true)][string]$Value)
    $quote = [string][char]39
    return $Value.Replace($quote, ($quote + '"' + $quote + '"' + $quote))
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

$remoteManagedDir = "$remoteHome/.local/share/pi-notify"
$remotePiDir = Resolve-NotifyBridgeRemotePiDir -PathValue $RemotePiDir -RemoteHome $remoteHome

& (Join-Path $PSScriptRoot 'install-remote-windows-notify.ps1') -RemoteHostAlias $RemoteHostAlias -RemotePiDir $RemotePiDir -ConfigPath $config.ConfigPath -ListenHost $config.ListenHost -Port $config.Port -Token $config.Token -SshExecutable $sshExe

$remoteServiceName = 'pi-remote-windows-notify-ensure'
$remoteServicePath = "$remoteHome/.config/systemd/user/$remoteServiceName.service"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-linux.' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempRoot

try {
    $tempScript = Join-Path $tempRoot 'pi-notify-bridge-ensure.sh'
    $tempUnit = Join-Path $tempRoot "$remoteServiceName.service"

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

    $ensureScript = @'
#!/usr/bin/env bash
set -euo pipefail
managed_dir='__MANAGED_DIR__'
pi_dir='__PI_DIR__'
mkdir -p "$pi_dir/extensions"
install -m 0644 "$managed_dir/remote-windows-notify.ts" "$pi_dir/extensions/remote-windows-notify.ts"
package_root="$pi_dir/git/github.com/zk541040600/pi_remote-windows-notify"
if [ -d "$package_root" ]; then
  find "$package_root" -type f -name remote-windows-notify.ts -print0 | while IFS= read -r -d '' dest; do
    install -m 0644 "$managed_dir/remote-windows-notify.ts" "$dest"
  done
fi
install -m 0600 "$managed_dir/remote-windows-notify.json" "$pi_dir/remote-windows-notify.json"
echo "Pi notify bridge ensured in $pi_dir"
'@
    $ensureScript = $ensureScript.Replace('__MANAGED_DIR__', (ConvertTo-SingleQuotedShellContent -Value $remoteManagedDir)).Replace('__PI_DIR__', (ConvertTo-SingleQuotedShellContent -Value $remotePiDir))
    [System.IO.File]::WriteAllText($tempScript, $ensureScript.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $serviceUnit = @"
[Unit]
Description=Ensure Pi remote Windows notify bridge files exist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$remoteManagedDir/pi-notify-bridge-ensure.sh

[Install]
WantedBy=default.target
"@
    [System.IO.File]::WriteAllText($tempUnit, $serviceUnit.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $mkdirManagedCommand = ('mkdir -p {0}' -f (ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir))
    & $sshExe @sshOptions $RemoteHostAlias $mkdirManagedCommand
    if ($LASTEXITCODE -ne 0) { throw "Failed to create remote managed dir on $RemoteHostAlias." }

    Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath (Join-Path $PSScriptRoot 'remote-windows-notify.ts') -RemotePath "$remoteManagedDir/remote-windows-notify.ts"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed extension to $RemoteHostAlias." }

    Copy-NotifyBridgeTextToRemotePath @remoteTransferArgs -Content $remoteConfigJson -RemotePath "$remoteManagedDir/remote-windows-notify.json" -Mode '0600'
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed config to $RemoteHostAlias." }

    Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $tempScript -RemotePath "$remoteManagedDir/pi-notify-bridge-ensure.sh"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload ensure script to $RemoteHostAlias." }

    Copy-NotifyBridgeFileToRemotePath @remoteTransferArgs -LocalPath $tempUnit -RemotePath "$remoteManagedDir/$remoteServiceName.service"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload systemd unit to $RemoteHostAlias." }

    $enableCommand = @"
set -euo pipefail
unit_dir="`$HOME/.config/systemd/user"
mkdir -p "`$unit_dir"
chmod 755 $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value "$remoteManagedDir/pi-notify-bridge-ensure.sh")
install -m 0644 $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value "$remoteManagedDir/$remoteServiceName.service") "`$unit_dir/$remoteServiceName.service"
if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteServiceName) >/dev/null 2>&1; then
  systemctl --user is-enabled $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteServiceName)
  systemctl --user --no-pager --full status $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteServiceName) | sed -n '1,20p' || true
else
  tmp_cron="`$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'pi-notify-bridge-ensure.sh' > "`$tmp_cron" || true
  printf '@reboot %s/pi-notify-bridge-ensure.sh >/dev/null 2>&1\n' $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value $remoteManagedDir) >> "`$tmp_cron"
  crontab "`$tmp_cron"
  rm -f "`$tmp_cron"
  $(ConvertTo-NotifyBridgeRemoteShellLiteral -Value "$remoteManagedDir/pi-notify-bridge-ensure.sh")
  echo 'installed via user crontab @reboot fallback'
fi
"@
    & $sshExe @sshOptions $RemoteHostAlias $enableCommand
    if ($LASTEXITCODE -ne 0) { throw "Failed to enable remote user autostart on $RemoteHostAlias." }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Linux Pi notify auto-start installed.'
Write-Host ('Remote host   : {0}' -f $RemoteHostAlias)
Write-Host ('Managed dir   : {0}' -f $remoteManagedDir)
Write-Host ('Remote Pi dir : {0}' -f $remotePiDir)
Write-Host ('User service : {0}' -f $remoteServicePath)
Write-Host 'Fallback     : user crontab @reboot when systemd --user is unavailable'
