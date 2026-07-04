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
    [int]$TunnelStartupDelaySeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

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
$sshExecutable = $config.SshExecutable
$scpExecutable = Resolve-NotifyBridgeScpExecutable -SshExecutable $sshExecutable

$remoteHome = (& $sshExecutable $RemoteHostAlias 'printf %s "$HOME"').Trim()
if ([string]::IsNullOrWhiteSpace($remoteHome)) {
    throw "Failed to resolve remote HOME on $RemoteHostAlias."
}

$remotePiDirResolved = Resolve-NotifyBridgeRemotePath -RemotePath $RemotePiDir -RemoteHome $remoteHome
& (Join-Path $PSScriptRoot 'install-remote-windows-notify.ps1') -RemoteHostAlias $RemoteHostAlias -RemotePiDir $remotePiDirResolved -ConfigPath $config.ConfigPath -ListenHost $config.ListenHost -Port $config.Port -Token $config.Token -SshExecutable $sshExecutable

$remoteManagedDir = "$remoteHome/.local/share/pi-notify"
$remoteServiceName = 'pi-remote-windows-notify-ensure'
$remoteServicePath = "/etc/systemd/system/$remoteServiceName.service"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-linux.' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempRoot

try {
    $tempConfig = Join-Path $tempRoot 'remote-windows-notify.json'
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
    [System.IO.File]::WriteAllText($tempConfig, ($remoteConfig | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    $ensureScript = @'
#!/usr/bin/env bash
set -euo pipefail
managed_dir='__MANAGED_DIR__'
pi_dir='__PI_DIR__'
mkdir -p "$pi_dir/extensions"
install -m 0644 "$managed_dir/remote-windows-notify.ts" "$pi_dir/extensions/remote-windows-notify.ts"
install -m 0644 "$managed_dir/remote-windows-notify.json" "$pi_dir/remote-windows-notify.json"
echo "Pi notify bridge ensured in $pi_dir"
'@
    $ensureScript = $ensureScript.Replace('__MANAGED_DIR__', $remoteManagedDir).Replace('__PI_DIR__', $remotePiDirResolved)
    [System.IO.File]::WriteAllText($tempScript, $ensureScript.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $serviceUnit = @"
[Unit]
Description=Ensure Pi remote Windows notify bridge files exist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$remoteManagedDir/pi-notify-bridge-ensure.sh
User=root

[Install]
WantedBy=multi-user.target
"@
    [System.IO.File]::WriteAllText($tempUnit, $serviceUnit.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    & $sshExecutable $RemoteHostAlias "mkdir -p '$remoteManagedDir'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create remote managed dir on $RemoteHostAlias." }

    & $scpExecutable -q (Join-Path $PSScriptRoot 'remote-windows-notify.ts') "${RemoteHostAlias}:$remoteManagedDir/remote-windows-notify.ts"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed extension to $RemoteHostAlias." }

    & $scpExecutable -q $tempConfig "${RemoteHostAlias}:$remoteManagedDir/remote-windows-notify.json"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed config to $RemoteHostAlias." }

    & $scpExecutable -q $tempScript "${RemoteHostAlias}:$remoteManagedDir/pi-notify-bridge-ensure.sh"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload ensure script to $RemoteHostAlias." }

    & $scpExecutable -q $tempUnit "${RemoteHostAlias}:$remoteManagedDir/$remoteServiceName.service"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload systemd unit to $RemoteHostAlias." }

    & $sshExecutable $RemoteHostAlias "chmod 755 '$remoteManagedDir/pi-notify-bridge-ensure.sh' && install -m 0644 '$remoteManagedDir/$remoteServiceName.service' '$remoteServicePath' && systemctl daemon-reload && systemctl enable --now '$remoteServiceName.service' && systemctl is-enabled '$remoteServiceName.service' && systemctl --no-pager --full status '$remoteServiceName.service' | sed -n '1,20p'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to enable remote systemd service on $RemoteHostAlias." }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Linux Pi notify auto-start installed.'
Write-Host ('Remote host   : {0}' -f $RemoteHostAlias)
Write-Host ('Remote Pi dir : {0}' -f $remotePiDirResolved)
Write-Host ('Managed dir   : {0}' -f $remoteManagedDir)
Write-Host ('Systemd unit  : {0}' -f $remoteServicePath)
