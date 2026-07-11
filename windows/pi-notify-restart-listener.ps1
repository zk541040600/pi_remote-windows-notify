param(
    [string]$ConfigPath = "$env:USERPROFILE\.pi-notify\config.json",
    [int]$TimeoutSeconds = 60,
    [switch]$Worker,
    [string]$StatusPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/NotifyBridge.Process.ps1"
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$baseDir = Split-Path -Parent $ConfigPath
$binDir = Join-Path $baseDir 'bin'
$instancePaths = @($ConfigPath, $binDir, $baseDir)
$logDir = Join-Path $baseDir 'logs'
$listenerPath = Join-Path $binDir 'notify-listener.ps1'
$runnerPath = Join-Path $binDir 'pi-notify-listener-runner.ps1'
$pidPath = Join-Path $baseDir 'listener.pid'

function Sync-LocalRuntimeFiles {
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
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $binDir $name
        if (Test-Path -LiteralPath $source) {
            if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($destination)) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        }
    }
}

function Write-RestartLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Write-Status {
    param(
        [string]$Status,
        [string]$Message,
        [int]$PidValue = 0,
        [int]$PortValue = 0
    )
    if ([string]::IsNullOrWhiteSpace($StatusPath)) { return }
    $payload = @{
        status = $Status
        message = $Message
        pid = $PidValue
        port = $PortValue
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText($StatusPath, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
}

function Test-HttpHealth {
    param([int]$Port)
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/health")
        $req.Timeout = 700
        $req.ReadWriteTimeout = 700
        $resp = $req.GetResponse()
        try { return ([int]$resp.StatusCode -eq 200) }
        finally { $resp.Close() }
    }
    catch { return $false }
}

function Get-NewListenerPid {
    if (-not (Test-Path -LiteralPath $pidPath)) { return 0 }
    $raw = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
    $pidValue = 0
    if ([int]::TryParse($raw.Trim(), [ref]$pidValue)) { return $pidValue }
    return 0
}

function Test-NewListenerAlive {
    $pidValue = Get-NewListenerPid
    if ($pidValue -le 0) { return $false }
    try {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $pidValue) -ErrorAction Stop
        if ($null -eq $process) { return $false }
        $commandLine = [string]$process.CommandLine
        return (($commandLine -like '*pi-notify-listener-runner.ps1*') -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $instancePaths))
    }
    catch { return $false }
}

function Stop-NotifyProcessId {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    try {
        $processInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -ne $processInfo -and -not (Test-NotifyBridgeProcessOwnedByPaths -CommandLine ([string]$processInfo.CommandLine) -OwnedPaths $instancePaths)) {
            Write-RestartLog ('skip unowned listener process pid={0} reason={1}' -f $ProcessId, $Reason)
            return
        }
        Start-Process -FilePath 'taskkill.exe' -ArgumentList (Join-NotifyBridgeProcessArguments @('/PID', $ProcessId, '/F', '/T')) -WindowStyle Hidden -Wait | Out-Null
        Write-RestartLog ('stopped listener process pid={0} reason={1}' -f $ProcessId, $Reason)
    }
    catch {
        Write-RestartLog ('listener process pid={0} not stopped reason={1}: {2}' -f $ProcessId, $Reason, $_.Exception.Message)
    }
}

function Stop-ExistingListenerProcesses {
    $ids = @()
    if (Test-Path -LiteralPath $pidPath) {
        $raw = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
        $pidValue = 0
        if ([int]::TryParse($raw.Trim(), [ref]$pidValue)) { $ids += $pidValue }
    }
    $ids += Get-NotifyBridgeScriptProcessIds -ScriptName 'notify-listener.ps1' -OwnedPaths $instancePaths
    $ids += Get-NotifyBridgeScriptProcessIds -ScriptName 'pi-notify-listener-runner.ps1' -OwnedPaths $instancePaths
    foreach ($processId in @($ids | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        Stop-NotifyProcessId -ProcessId $processId -Reason 'listener-restart'
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Worker {
    New-Item -ItemType Directory -Force -Path $baseDir, $binDir, $logDir | Out-Null
    Sync-LocalRuntimeFiles
    if (-not (Test-Path -LiteralPath $listenerPath)) { throw "missing $listenerPath" }
    if (-not (Test-Path -LiteralPath $runnerPath)) { throw "missing $runnerPath" }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "missing $ConfigPath" }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($listenerPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw $parseErrors[0].Message }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $port = [int]$config.port
    if ($port -le 0) { throw "bad port in $ConfigPath" }

    Stop-ExistingListenerProcesses

    Start-Sleep -Milliseconds 300
    $runnerCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}"' -f (Get-Command powershell.exe).Source, $runnerPath, $ConfigPath)
    Start-NotifyBridgeDetachedCommand -CommandLine $runnerCommand -Name 'listener'

    $maxAttempts = [Math]::Max(6, ([Math]::Max(3, $TimeoutSeconds) * 2))
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        Start-Sleep -Milliseconds 500
        $alive = Test-NewListenerAlive
        $healthy = Test-HttpHealth -Port $port
        $listenerPid = Get-NewListenerPid
        Write-RestartLog ('listener poll attempt={0} alive={1} healthy={2}' -f $i, $alive, $healthy)
        if ($alive -and $healthy) {
            Write-RestartLog "listener restarted pid=$listenerPid port=$port"
            Write-Status -Status 'ok' -Message 'listener restarted' -PidValue $listenerPid -PortValue $port
            return
        }
    }

    $stalePid = Get-NewListenerPid
    if ($stalePid -gt 0) { try { Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue } catch {} }
    throw "listener did not become healthy on port $port"
}

if ($Worker) {
    try { Invoke-Worker }
    catch {
        Write-RestartLog "restart failed: $($_.Exception.Message)"
        Write-Status -Status 'error' -Message $_.Exception.Message
        exit 1
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Join-Path $logDir 'restart-listener.status.json' }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $logDir 'restart-listener.log' }
Remove-Item -LiteralPath $StatusPath -Force -ErrorAction SilentlyContinue

$workerProcess = Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList (Join-NotifyBridgeProcessArguments @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $PSCommandPath,
    '-Worker',
    '-ConfigPath', $ConfigPath,
    '-StatusPath', $StatusPath,
    '-LogPath', $LogPath
)) -PassThru

$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(3, $TimeoutSeconds))
while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $StatusPath) {
        $status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
        if ([string]$status.status -eq 'ok') {
            Write-Host ('listener restarted pid={0} port={1}' -f $status.pid, $status.port)
            exit 0
        }
        if ([string]$status.status -eq 'error') {
            throw ([string]$status.message)
        }
    }
    Start-Sleep -Milliseconds 250
}

try { Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
throw ('listener restart timed out after {0}s; see {1}' -f $TimeoutSeconds, $LogPath)
