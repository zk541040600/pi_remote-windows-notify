# Quote one value as a POSIX shell literal for remote commands.
function ConvertTo-NotifyBridgeRemoteShellLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $quote = [string][char]39
    $escaped = $Value.Replace($quote, ($quote + '"' + $quote + '"' + $quote))
    return ($quote + $escaped + $quote)
}

# Resolve a configured Pi directory against the remote user's home directory.
function Resolve-NotifyBridgeRemotePiDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHome
    )

    $normalizedHome = $RemoteHome.TrimEnd('/')
    $value = if ([string]::IsNullOrWhiteSpace($PathValue)) { '~/.pi/agent' } else { $PathValue.Trim() }
    if ($value -eq '~') {
        return $normalizedHome
    }
    if ($value.StartsWith('~/')) {
        return ($normalizedHome + '/' + $value.Substring(2).TrimStart('/')).TrimEnd('/')
    }
    if ($value.StartsWith('/')) {
        return $value.TrimEnd('/')
    }
    return ($normalizedHome + '/' + $value.TrimStart('/')).TrimEnd('/')
}

# Quote one argv value for ProcessStartInfo.Arguments on Windows PowerShell 5.1.
function ConvertTo-NotifyBridgeWindowsProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return ('"{0}"' -f $escaped)
}

# Probe whether one SSH executable can run the required non-interactive command.
function Test-NotifyBridgeSshExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SshPath,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string[]]$SshOptions
    )

    if ([string]::IsNullOrWhiteSpace($SshPath)) { return $false }
    if (-not (Test-NotifyBridgeExecutableAvailable -Value $SshPath)) { return $false }

    $probeArgs = @($SshOptions + @($RemoteHost, 'printf __pi_notify_ssh_ok__')) | ForEach-Object { ConvertTo-NotifyBridgeWindowsProcessArgument -Value ([string]$_) }
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

# Select the first SSH executable that passes the bridge's non-interactive probe.
function Resolve-NotifyBridgeWorkingSshExecutable {
    [CmdletBinding()]
    param(
        [string]$PreferredSshExe,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string[]]$SshOptions
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
        if (Test-NotifyBridgeSshExecutable -SshPath $candidate -RemoteHost $RemoteHost -SshOptions $SshOptions) {
            if (-not [string]::IsNullOrWhiteSpace($PreferredSshExe) -and $candidate -ne $PreferredSshExe) {
                Write-Warning ('Configured sshExecutable did not pass a non-interactive probe; using {0}' -f $candidate)
            }
            return $candidate
        }
    }
    throw ('No ssh executable can run a non-interactive command on {0}.' -f $RemoteHost)
}

# Stream bytes through SSH while preserving the existing mode and LASTEXITCODE contract.
function Send-NotifyBridgeRemoteBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$ContentBytes,
        [Parameter(Mandatory = $true)]
        [string]$SshExecutable,
        [Parameter(Mandatory = $true)]
        [string[]]$SshOptions,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode
    )

    $encoded = [Convert]::ToBase64String($ContentBytes)
    $remoteLiteral = ConvertTo-NotifyBridgeRemoteShellLiteral -Value $RemotePath
    $uploadCommand = ('umask 077; base64 -d > {0}; chmod {1} {0}' -f $remoteLiteral, $Mode)
    $sshArgs = @($SshOptions + @($RemoteHost, $uploadCommand)) | ForEach-Object { ConvertTo-NotifyBridgeWindowsProcessArgument -Value ([string]$_) }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $SshExecutable
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

# Upload one local file without creating an intermediate remote or local token file.
function Copy-NotifyBridgeFileToRemotePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        [Parameter(Mandatory = $true)]
        [string]$SshExecutable,
        [Parameter(Mandatory = $true)]
        [string[]]$SshOptions,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '0644'
    )

    Send-NotifyBridgeRemoteBytes -ContentBytes ([System.IO.File]::ReadAllBytes($LocalPath)) -SshExecutable $SshExecutable -SshOptions $SshOptions -RemoteHost $RemoteHost -RemotePath $RemotePath -Mode $Mode
}

# Upload UTF-8 text directly from memory so token-bearing JSON never touches TEMP.
function Copy-NotifyBridgeTextToRemotePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$SshExecutable,
        [Parameter(Mandatory = $true)]
        [string[]]$SshOptions,
        [Parameter(Mandatory = $true)]
        [string]$RemoteHost,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '0600'
    )

    Send-NotifyBridgeRemoteBytes -ContentBytes ([System.Text.Encoding]::UTF8.GetBytes($Content)) -SshExecutable $SshExecutable -SshOptions $SshOptions -RemoteHost $RemoteHost -RemotePath $RemotePath -Mode $Mode
}
