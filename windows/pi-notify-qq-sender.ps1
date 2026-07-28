[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)]
    [string]$TextFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:NotifyQqLogPath = $null
$script:NotifyQqLogMutexName = $null

# Append one redacted worker result while serializing concurrent sender processes.
function Write-NotifyQqSenderLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($script:NotifyQqLogPath) -or [string]::IsNullOrWhiteSpace($script:NotifyQqLogMutexName)) {
        return
    }

    $mutex = $null
    $lockTaken = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $script:NotifyQqLogMutexName)
        try {
            $lockTaken = $mutex.WaitOne(2000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            return
        }

        $line = ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message, [System.Environment]::NewLine)
        [System.IO.File]::AppendAllText($script:NotifyQqLogPath, $line, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Worker logging is best-effort and must not expose sender diagnostics.
    }
    finally {
        if ($lockTaken -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

$process = $null
try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $TextFile = [System.IO.Path]::GetFullPath($TextFile)
    $baseDir = Split-Path -Parent $ConfigPath
    $logDir = Join-Path $baseDir 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:NotifyQqLogPath = Join-Path $logDir 'qq-sender.log'

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $configHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))
        $script:NotifyQqLogMutexName = 'Local\PiNotifyQqLog_' + ([System.BitConverter]::ToString($configHash).Replace('-', '').Substring(0, 16))
    }
    finally {
        $sha.Dispose()
    }

    . "$PSScriptRoot/NotifyBridge.Common.ps1"

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-NotifyQqSenderLog -Message 'qq-send-unavailable reason=config'
        return
    }

    try {
        $rawConfig = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
        $config = $rawConfig | ConvertFrom-Json
    }
    catch {
        Write-NotifyQqSenderLog -Message 'qq-send-unavailable reason=config'
        return
    }

    $enabled = $false
    if ($config.PSObject.Properties['qqNotifyEnabled']) {
        $enabled = ConvertTo-NotifyBridgeBoolean -Value $config.qqNotifyEnabled -Default $false
    }
    if (-not $enabled) {
        Write-NotifyQqSenderLog -Message 'qq-send-skip reason=disabled'
        return
    }

    $nodeExecutable = if ($config.PSObject.Properties['qqNodeExecutable']) { [string]$config.qqNodeExecutable } else { '' }
    if ([string]::IsNullOrWhiteSpace($nodeExecutable) -or -not (Test-NotifyBridgeExecutableAvailable -Value $nodeExecutable)) {
        Write-NotifyQqSenderLog -Message 'qq-send-unavailable reason=node'
        return
    }
    $nodeExecutable = Resolve-NotifyBridgeExecutableValue -Value $nodeExecutable

    $senderScript = if ($config.PSObject.Properties['qqSenderScript']) { [string]$config.qqSenderScript } else { '' }
    if ([string]::IsNullOrWhiteSpace($senderScript) -or -not (Test-Path -LiteralPath $senderScript -PathType Leaf)) {
        Write-NotifyQqSenderLog -Message 'qq-send-unavailable reason=sender'
        return
    }

    if (-not (Test-Path -LiteralPath $TextFile -PathType Leaf)) {
        Write-NotifyQqSenderLog -Message 'qq-send-unavailable reason=text-file'
        return
    }

    $timeoutSeconds = 20
    if ($config.PSObject.Properties['qqSendTimeoutSeconds']) {
        $configuredTimeout = 0
        if ([int]::TryParse([string]$config.qqSendTimeoutSeconds, [ref]$configuredTimeout) -and $configuredTimeout -ge 1) {
            $timeoutSeconds = [Math]::Min(120, $configuredTimeout)
        }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $nodeExecutable
    $startInfo.Arguments = Join-NotifyBridgeProcessArguments @($senderScript, '--text-file', $TextFile)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        Write-NotifyQqSenderLog -Message 'qq-send-error reason=ProcessStartFailed'
        return
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        try { $process.WaitForExit(2000) } catch {}
        try { $null = $stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $null = $stderrTask.GetAwaiter().GetResult() } catch {}
        Write-NotifyQqSenderLog -Message 'qq-send-timeout'
        return
    }

    try { $null = $stdoutTask.GetAwaiter().GetResult() } catch {}
    try { $null = $stderrTask.GetAwaiter().GetResult() } catch {}
    if ([int]$process.ExitCode -eq 0) {
        Write-NotifyQqSenderLog -Message 'qq-send-ok'
    }
    else {
        Write-NotifyQqSenderLog -Message ('qq-send-failed exitCode={0}' -f [int]$process.ExitCode)
    }
}
catch {
    Write-NotifyQqSenderLog -Message ('qq-send-error reason={0}' -f $_.Exception.GetType().Name)
}
finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($TextFile) -and (Test-Path -LiteralPath $TextFile)) {
            Remove-Item -LiteralPath $TextFile -Force -ErrorAction Stop
        }
    }
    catch {
        Write-NotifyQqSenderLog -Message ('qq-send-cleanup-failed reason={0}' -f $_.Exception.GetType().Name)
    }
}
