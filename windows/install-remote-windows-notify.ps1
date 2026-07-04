[CmdletBinding()]
param(
    [string]$RemoteHostAlias = "my",
    [string]$RemotePiDir = "~/.pi/agent",
    [string]$ConfigPath,
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$SshExecutable
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
$config = Ensure-NotifyBridgeConfig @configArgs
$sshExecutable = $config.SshExecutable
$scpExecutable = Resolve-NotifyBridgeScpExecutable -SshExecutable $sshExecutable
$templatePath = Join-Path $PSScriptRoot 'remote-windows-notify.ts'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Extension template not found: $templatePath"
}

$remoteExtensionDir = "$RemotePiDir/extensions"
$remoteExtensionPath = "$remoteExtensionDir/remote-windows-notify.ts"
$remoteConfigPath = "$RemotePiDir/remote-windows-notify.json"

$tempConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-windows-notify.{0}.json" -f [Guid]::NewGuid().ToString('N'))
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
[System.IO.File]::WriteAllText(
    $tempConfigPath,
    ($remoteConfig | ConvertTo-Json -Depth 6),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Installing remote Pi notify bridge on $RemoteHostAlias ..."
& $sshExecutable $RemoteHostAlias "mkdir -p $remoteExtensionDir"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create remote extension directory on $RemoteHostAlias."
}

& $scpExecutable -q $templatePath "${RemoteHostAlias}:$remoteExtensionPath"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote extension to $RemoteHostAlias."
}

& $scpExecutable -q $tempConfigPath "${RemoteHostAlias}:$remoteConfigPath"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote config to $RemoteHostAlias."
}

Remove-Item -LiteralPath $tempConfigPath -Force -ErrorAction SilentlyContinue

& $sshExecutable $RemoteHostAlias "test -f $remoteExtensionPath && test -f $remoteConfigPath && printf 'REMOTE_INSTALLED=1\nEXT=%s\nCFG=%s\n' '$remoteExtensionPath' '$remoteConfigPath'"
if ($LASTEXITCODE -ne 0) {
    throw "Remote verify failed on $RemoteHostAlias."
}

Write-Host ""
Write-Host "Installed successfully."
Write-Host "Local listener config : $($config.ConfigPath)"
Write-Host "Local listener URL    : $($config.LocalUrl)"
Write-Host "Remote tunnel URL     : $($config.RemoteUrl)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Start local listener:"
Write-Host "   powershell.exe -ExecutionPolicy Bypass -File .\windows\notify-listener.ps1"
Write-Host "2. Connect with reverse tunnel:"
Write-Host "   ssh -R 127.0.0.1:$($config.Port):127.0.0.1:$($config.Port) $RemoteHostAlias"
Write-Host "3. In Pi on $RemoteHostAlias, run /reload if it is already open."
