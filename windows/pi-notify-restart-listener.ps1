param(
    [string]$ConfigPath = "$env:USERPROFILE\.pi-notify\config.json",
    [int]$TimeoutSeconds = 60,
    [switch]$Worker,
    [string]$StatusPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$baseDir = Split-Path -Parent $ConfigPath
$binDir = Join-Path $baseDir 'bin'
$logDir = Join-Path $baseDir 'logs'
$listenerPath = Join-Path $binDir 'notify-listener.ps1'
$runnerPath = Join-Path $binDir 'pi-notify-listener-runner.ps1'
$pidPath = Join-Path $baseDir 'listener.pid'

function ConvertTo-NotifyProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    $text = [string]$Value
    if ($text.Length -eq 0) { return '""' }
    if ($text -notmatch '[\s"]') { return $text }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq '\') { $backslashCount += 1; continue }
        if ($ch -eq '"') {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NotifyProcessArguments {
    param([object[]]$ArgumentList)
    return (@($ArgumentList) | ForEach-Object { ConvertTo-NotifyProcessArgument -Value ([string]$_) }) -join ' '
}

function Start-NotifyDetachedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,
        [string]$Name = 'listener'
    )

    $vbsPath = Join-Path $env:TEMP ('pi-notify-{0}-start-{1}-{2}.vbs' -f $Name, $PID, ([Guid]::NewGuid().ToString('N')))
    $escapedCommand = $CommandLine.Replace('"', '""')
    $content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escapedCommand", 0, False
"@
    [System.IO.File]::WriteAllText($vbsPath, $content.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $taskName = 'PiNotifyStart_{0}_{1}' -f $Name, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument (Join-NotifyProcessArguments @($vbsPath))
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 6
        return
    }
    catch {
        Start-Process -FilePath 'wscript.exe' -ArgumentList (Join-NotifyProcessArguments @($vbsPath)) -WindowStyle Hidden | Out-Null
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Sync-LocalRuntimeFiles {
    $runtimeFiles = @(
        'NotifyBridge.Common.ps1',
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

function Test-NewListenerAlive {
    param([System.Diagnostics.Process]$Process)
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
    }
    catch { return $false }

    if (-not (Test-Path -LiteralPath $pidPath)) { return $false }
    $raw = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
    $pidValue = 0
    return ([int]::TryParse($raw.Trim(), [ref]$pidValue) -and $pidValue -eq $Process.Id)
}

function Test-NotifyCommandLineContainsPath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $needle = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $start = 0
    while ($start -lt $CommandLine.Length) {
        $index = $CommandLine.IndexOf($needle, $start, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { return $false }
        $end = $index + $needle.Length
        if ($end -ge $CommandLine.Length) { return $true }
        $next = [string]$CommandLine[$end]
        if ([char]::IsWhiteSpace($CommandLine[$end]) -or $next -eq '"' -or $next -eq "'" -or $next -eq '\' -or $next -eq '/') { return $true }
        $start = $index + 1
    }
    return $false
}

function Test-NotifyProcessOwnedByThisInstance {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($needle in @($ConfigPath, $binDir, $baseDir)) {
        if (Test-NotifyCommandLineContainsPath -CommandLine $CommandLine -Path $needle) { return $true }
    }
    return $false
}

function Get-NotifyScriptProcessIds {
    param([string]$ScriptName)

    $processIds = @()
    $escaped = [regex]::Escape($ScriptName)
    try {
        $items = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $commandLine = [string]$_.CommandLine
            ($_.ProcessId -ne $PID) -and (Test-NotifyProcessOwnedByThisInstance -CommandLine $commandLine) -and ($commandLine -match ('(?i)-File\s+("[^"]*{0}"|[^\s"]*{0})' -f $escaped))
        } | Select-Object -ExpandProperty ProcessId
        foreach ($processId in $items) {
            if ($processId) { $processIds += [int]$processId }
        }
    }
    catch {
    }

    return @($processIds | Select-Object -Unique)
}

function Stop-NotifyProcessId {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    try {
        $processInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -ne $processInfo -and -not (Test-NotifyProcessOwnedByThisInstance -CommandLine ([string]$processInfo.CommandLine))) {
            Write-RestartLog ('skip unowned listener process pid={0} reason={1}' -f $ProcessId, $Reason)
            return
        }
        Start-Process -FilePath 'taskkill.exe' -ArgumentList (Join-NotifyProcessArguments @('/PID', $ProcessId, '/F', '/T')) -WindowStyle Hidden -Wait | Out-Null
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
    $ids += Get-NotifyScriptProcessIds -ScriptName 'notify-listener.ps1'
    $ids += Get-NotifyScriptProcessIds -ScriptName 'pi-notify-listener-runner.ps1'
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
    $listener = Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList (Join-NotifyProcessArguments @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runnerPath,
        '-ConfigPath', $ConfigPath
    )) -PassThru

    $maxAttempts = [Math]::Max(6, ([Math]::Max(3, $TimeoutSeconds) * 2))
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        Start-Sleep -Milliseconds 500
        $alive = Test-NewListenerAlive -Process $listener
        $healthy = Test-HttpHealth -Port $port
        Write-RestartLog ('listener poll attempt={0} alive={1} healthy={2}' -f $i, $alive, $healthy)
        if ($alive -and $healthy) {
            Write-RestartLog "listener restarted pid=$($listener.Id) port=$port"
            Write-Status -Status 'ok' -Message 'listener restarted' -PidValue $listener.Id -PortValue $port
            return
        }
    }

    try { Stop-Process -Id $listener.Id -Force -ErrorAction SilentlyContinue } catch {}
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

$workerProcess = Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList (Join-NotifyProcessArguments @(
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
