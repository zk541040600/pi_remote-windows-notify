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

function ConvertTo-RemoteShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    $quote = [string][char]39
    return ($quote + (ConvertTo-SingleQuotedShellContent -Value $Value) + $quote)
}

function ConvertTo-WindowsProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return ('"{0}"' -f $escaped)
}


function Test-NotifySshExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SshPath,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost
    )

    if ([string]::IsNullOrWhiteSpace($SshPath)) { return $false }
    if (-not (Test-NotifyBridgeExecutableAvailable -Value $SshPath)) { return $false }

    $probeArgs = @($sshOptions + @($RemoteHost, 'printf __pi_notify_ssh_ok__')) | ForEach-Object { ConvertTo-WindowsProcessArgument -Value ([string]$_) }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $SshPath
    $startInfo.Arguments = ($probeArgs -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    if (-not $process.WaitForExit(12000)) {
        try { $process.Kill() } catch {}
        return $false
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    return ($process.ExitCode -eq 0 -and $stdout.Contains('__pi_notify_ssh_ok__'))
}

function Resolve-WorkingNotifySshExecutable {
    param(
        [string]$PreferredSshExe,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost
    )

    $candidates = @(
        $PreferredSshExe,
        [System.IO.Path]::Combine($env:WINDIR, 'System32', 'OpenSSH', 'ssh.exe'),
        [System.IO.Path]::Combine($env:ProgramFiles, 'Git', 'usr', 'bin', 'ssh.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'Git', 'usr', 'bin', 'ssh.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Atlassian', 'SourceTree', 'git_local', 'usr', 'bin', 'ssh.exe'),
        'ssh.exe'
    )
    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-NotifySshExecutable -SshPath $candidate -RemoteHost $RemoteHost) {
            if (-not [string]::IsNullOrWhiteSpace($PreferredSshExe) -and $candidate -ne $PreferredSshExe) {
                Write-Warning ('Configured sshExecutable did not pass a non-interactive probe; using {0}' -f $candidate)
            }
            return $candidate
        }
    }
    throw ('No ssh executable can run a non-interactive command on {0}.' -f $RemoteHost)
}

function Copy-FileToRemotePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '0644'
    )

    $encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($LocalPath))
    $uploadCommand = ('umask 077; base64 -d > {0}; chmod {1} {0}' -f (ConvertTo-RemoteShellLiteral -Value $RemotePath), $Mode)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $sshExe
    $sshArgs = @($sshOptions + @($RemoteHost, $uploadCommand)) | ForEach-Object { ConvertTo-WindowsProcessArgument -Value ([string]$_) }
    $startInfo.Arguments = ($sshArgs -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $inputBytes = [System.Text.Encoding]::ASCII.GetBytes($encoded + "`n")
    $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
    if ($process.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Host $stderr.TrimEnd() }
        $global:LASTEXITCODE = $process.ExitCode
        return
    }
    $global:LASTEXITCODE = 0
}
function Copy-TextToRemotePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '0600'
    )

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
    $uploadCommand = ('umask 077; base64 -d > {0}; chmod {1} {0}' -f (ConvertTo-RemoteShellLiteral -Value $RemotePath), $Mode)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $sshExe
    $sshArgs = @($sshOptions + @($RemoteHost, $uploadCommand)) | ForEach-Object { ConvertTo-WindowsProcessArgument -Value ([string]$_) }
    $startInfo.Arguments = ($sshArgs -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $inputBytes = [System.Text.Encoding]::ASCII.GetBytes($encoded + "`n")
    $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
    if ($process.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Host $stderr.TrimEnd() }
        $global:LASTEXITCODE = $process.ExitCode
        return
    }
    $global:LASTEXITCODE = 0
}


function Resolve-RemotePiDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHome
    )

    $value = if ([string]::IsNullOrWhiteSpace($PathValue)) { '~/.pi/agent' } else { $PathValue.Trim() }
    if ($value -eq '~') {
        return $RemoteHome
    }
    if ($value.StartsWith('~/')) {
        return ($RemoteHome.TrimEnd('/') + '/' + $value.Substring(2))
    }
    if ($value.StartsWith('/')) {
        return $value
    }
    return ($RemoteHome.TrimEnd('/') + '/' + $value)
}

$sshExe = Resolve-WorkingNotifySshExecutable -PreferredSshExe $preferredSshExe -RemoteHost $RemoteHostAlias
if ($sshExe -ne [string]$config.SshExecutable) {
    $config = Ensure-NotifyBridgeConfig -ConfigPath $config.ConfigPath -SshExecutable $sshExe
}
$remoteHome = (& $sshExe @sshOptions $RemoteHostAlias 'printf %s "$HOME"').Trim()
if ([string]::IsNullOrWhiteSpace($remoteHome)) {
    throw "Failed to resolve remote HOME on $RemoteHostAlias."
}

$remoteManagedDir = "$remoteHome/.local/share/pi-notify"
$remotePiDir = Resolve-RemotePiDir -PathValue $RemotePiDir -RemoteHome $remoteHome

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

    $mkdirManagedCommand = ('mkdir -p {0}' -f (ConvertTo-RemoteShellLiteral -Value $remoteManagedDir))
    & $sshExe @sshOptions $RemoteHostAlias $mkdirManagedCommand
    if ($LASTEXITCODE -ne 0) { throw "Failed to create remote managed dir on $RemoteHostAlias." }

    Copy-FileToRemotePath -LocalPath (Join-Path $PSScriptRoot 'remote-windows-notify.ts') -RemoteHost $RemoteHostAlias -RemotePath "$remoteManagedDir/remote-windows-notify.ts"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed extension to $RemoteHostAlias." }

    Copy-TextToRemotePath -Content $remoteConfigJson -RemoteHost $RemoteHostAlias -RemotePath "$remoteManagedDir/remote-windows-notify.json" -Mode '0600'
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload managed config to $RemoteHostAlias." }

    Copy-FileToRemotePath -LocalPath $tempScript -RemoteHost $RemoteHostAlias -RemotePath "$remoteManagedDir/pi-notify-bridge-ensure.sh"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload ensure script to $RemoteHostAlias." }

    Copy-FileToRemotePath -LocalPath $tempUnit -RemoteHost $RemoteHostAlias -RemotePath "$remoteManagedDir/$remoteServiceName.service"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload systemd unit to $RemoteHostAlias." }

    $enableCommand = @"
set -euo pipefail
unit_dir="`$HOME/.config/systemd/user"
mkdir -p "`$unit_dir"
chmod 755 $(ConvertTo-RemoteShellLiteral -Value "$remoteManagedDir/pi-notify-bridge-ensure.sh")
install -m 0644 $(ConvertTo-RemoteShellLiteral -Value "$remoteManagedDir/$remoteServiceName.service") "`$unit_dir/$remoteServiceName.service"
if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now $(ConvertTo-RemoteShellLiteral -Value $remoteServiceName) >/dev/null 2>&1; then
  systemctl --user is-enabled $(ConvertTo-RemoteShellLiteral -Value $remoteServiceName)
  systemctl --user --no-pager --full status $(ConvertTo-RemoteShellLiteral -Value $remoteServiceName) | sed -n '1,20p' || true
else
  tmp_cron="`$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'pi-notify-bridge-ensure.sh' > "`$tmp_cron" || true
  printf '@reboot %s/pi-notify-bridge-ensure.sh >/dev/null 2>&1\n' $(ConvertTo-RemoteShellLiteral -Value $remoteManagedDir) >> "`$tmp_cron"
  crontab "`$tmp_cron"
  rm -f "`$tmp_cron"
  $(ConvertTo-RemoteShellLiteral -Value "$remoteManagedDir/pi-notify-bridge-ensure.sh")
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
