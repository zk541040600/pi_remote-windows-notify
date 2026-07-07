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
    'notify-listener.ps1',
    'pi-notify-listener-runner.ps1',
    'pi-notify-restart-listener.ps1',
    'pi-notify-popup.ps1',
    'pi-notify-activate.ps1',
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

function ConvertTo-RemoteShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    $quote = [string][char]39
    $escaped = $Value.Replace($quote, ($quote + '"' + $quote + '"' + $quote))
    return ($quote + $escaped + $quote)
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
        return $RemoteHome.TrimEnd('/')
    }
    if ($value.StartsWith('~/')) {
        return ($RemoteHome.TrimEnd('/') + '/' + $value.Substring(2).TrimStart('/'))
    }
    if ($value.StartsWith('/')) {
        return $value.TrimEnd('/')
    }
    return ($RemoteHome.TrimEnd('/') + '/' + $value.TrimStart('/')).TrimEnd('/')
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

$sshExe = Resolve-WorkingNotifySshExecutable -PreferredSshExe $preferredSshExe -RemoteHost $RemoteHostAlias
if ($sshExe -ne [string]$config.SshExecutable) {
    $config = Ensure-NotifyBridgeConfig -ConfigPath $config.ConfigPath -SshExecutable $sshExe
}
$remoteHome = (& $sshExe @sshOptions $RemoteHostAlias 'printf %s "$HOME"').Trim()
if ([string]::IsNullOrWhiteSpace($remoteHome)) {
    throw "Failed to resolve remote HOME on $RemoteHostAlias."
}

$remotePiDir = Resolve-RemotePiDir -PathValue $RemotePiDir -RemoteHome $remoteHome
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
$mkdirCommand = ('mkdir -p {0} {1}' -f (ConvertTo-RemoteShellLiteral -Value $remoteExtensionDir), (ConvertTo-RemoteShellLiteral -Value $remoteManagedDir))
& $sshExe @sshOptions $RemoteHostAlias $mkdirCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create remote extension directories on $RemoteHostAlias."
}

Copy-FileToRemotePath -LocalPath $templatePath -RemoteHost $RemoteHostAlias -RemotePath $remoteExtensionPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote extension to $RemoteHostAlias."
}

Copy-FileToRemotePath -LocalPath $templatePath -RemoteHost $RemoteHostAlias -RemotePath $remoteManagedExtensionPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote extension to $RemoteHostAlias."
}

$syncCommand = ('REMOTE_MANAGED_EXT={0} REMOTE_PI_DIR={1} python3 -' -f (ConvertTo-RemoteShellLiteral -Value $remoteManagedExtensionPath), (ConvertTo-RemoteShellLiteral -Value $remotePiDir))
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

Copy-TextToRemotePath -Content $remoteConfigJson -RemoteHost $RemoteHostAlias -RemotePath $remoteConfigPath -Mode '0600'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote config to $RemoteHostAlias."
}

Copy-TextToRemotePath -Content $remoteConfigJson -RemoteHost $RemoteHostAlias -RemotePath $remoteManagedConfigPath -Mode '0600'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload managed remote config to $RemoteHostAlias."
}

$verifyCommand = ('test -f {0} && test -f {1} && test -f {2} && test "$(stat -c ''%a'' {1})" = 600 && test "$(stat -c ''%a'' {2})" = 600 && printf ''REMOTE_INSTALLED=1\nEXT=%s\nCFG=%s\nMANAGED_CFG=%s\n'' {3} {4} {5}' -f (ConvertTo-RemoteShellLiteral -Value $remoteExtensionPath), (ConvertTo-RemoteShellLiteral -Value $remoteConfigPath), (ConvertTo-RemoteShellLiteral -Value $remoteManagedConfigPath), (ConvertTo-RemoteShellLiteral -Value $remoteExtensionPath), (ConvertTo-RemoteShellLiteral -Value $remoteConfigPath), (ConvertTo-RemoteShellLiteral -Value $remoteManagedConfigPath))
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
