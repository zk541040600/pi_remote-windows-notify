param(
    [string]$ConfigPath = "$env:USERPROFILE\.pi-notify\config.json",
    [string]$DisplayMode = "popup-focus",
    [int]$PopupTimeout = 300,
    [string]$PopupPlacement = "cursor",
    [int]$Port = 23118,
    [switch]$Pull,
    [switch]$SyncRemote,
    [string]$RemotePiDir = '~/.pi/agent',
    [switch]$SkipRemoteSync,
    [switch]$SkipTunnel
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/NotifyBridge.Common.ps1"
$repoDir = Split-Path -Parent $PSScriptRoot
$configPath = [System.IO.Path]::GetFullPath($ConfigPath)
$baseDir = Split-Path -Parent $configPath
$binDir = Join-Path $baseDir 'bin'
$piExtDir = "$env:USERPROFILE\.pi\agent\extensions"
$listenerPidPath = Join-Path $baseDir 'listener.pid'
$tunnelPidPath = Join-Path $baseDir 'tunnel.pid'

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
        [string]$Name = 'process'
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

function Stop-NotifyProcessId {
    param(
        [int]$ProcessId,
        [string]$Reason,
        [switch]$AllowParentScopedSsh,
        [int[]]$AllowedParentProcessIds = @()
    )

    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    try {
        $processInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        $isOwned = $false
        $isAllowedParentScopedSsh = $false
        if ($null -ne $processInfo) {
            $isOwned = Test-NotifyProcessOwnedByThisInstance -CommandLine ([string]$processInfo.CommandLine)
            $isAllowedParentScopedSsh = [bool]$AllowParentScopedSsh -and ([string]$processInfo.Name -eq 'ssh.exe') -and (@($AllowedParentProcessIds) -contains [int]$processInfo.ParentProcessId)
        }
        if ($null -ne $processInfo -and -not $isOwned -and -not $isAllowedParentScopedSsh) {
            Write-Host ('skip unowned process pid={0} name={1} parent={2} reason={3}' -f $ProcessId, $processInfo.Name, $processInfo.ParentProcessId, $Reason)
            return
        }
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        Start-Process -FilePath 'taskkill.exe' -ArgumentList (Join-NotifyProcessArguments @('/PID', $ProcessId, '/F', '/T')) -WindowStyle Hidden -Wait | Out-Null
        Write-Host ('stopped {0} pid={1} reason={2}' -f $process.ProcessName, $ProcessId, $Reason)
    }
    catch {
    }
}

function Stop-NotifyPidFile {
    param(
        [string]$Path,
        [string]$Reason
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $raw = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $processId = 0
        if ([int]::TryParse($raw.Trim(), [ref]$processId)) {
            Stop-NotifyProcessId -ProcessId $processId -Reason $Reason
        }
    }
    finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
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
    foreach ($needle in @($configPath, $binDir, $baseDir)) {
        if (Test-NotifyCommandLineContainsPath -CommandLine $CommandLine -Path $needle) { return $true }
    }
    return $false
}

function Get-NotifyScriptProcessIds {
    param([string]$ScriptName)

    $ids = @()
    $escaped = [regex]::Escape($ScriptName)
    try {
        $items = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $commandLine = [string]$_.CommandLine
            ($_.ProcessId -ne $PID) -and (Test-NotifyProcessOwnedByThisInstance -CommandLine $commandLine) -and ($commandLine -match ('(?i)-File\s+("[^"]*{0}"|[^\s"]*{0})' -f $escaped))
        }
        foreach ($item in $items) {
            if ($item.ProcessId) { $ids += [int]$item.ProcessId }
        }
    }
    catch {
    }

    return @($ids | Select-Object -Unique)
}

function Get-NotifyTunnelProcessIds {
    param([int]$Port)

    $ids = @(Get-NotifyScriptProcessIds -ScriptName 'pi-notify-reverse-tunnel.ps1')
    $wrapperIds = @($ids)
    $forwardNeedle = ('127.0.0.1:{0}:127.0.0.1:{0}' -f $Port)
    try {
        if ($wrapperIds.Count -gt 0) {
            $items = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                ($_.Name -eq 'ssh.exe') -and ([string]$_.CommandLine -like ('*{0}*' -f $forwardNeedle)) -and ($wrapperIds -contains $_.ParentProcessId)
            }
            foreach ($item in $items) {
                if ($item.ProcessId) { $ids += [int]$item.ProcessId }
            }
        }
    }
    catch {
    }

    return @($ids | Select-Object -Unique)
}

function Stop-NotifyTunnelProcesses {
    param([int]$Port)

    $wrapperIds = @(Get-NotifyScriptProcessIds -ScriptName 'pi-notify-reverse-tunnel.ps1')
    foreach ($processId in Get-NotifyTunnelProcessIds -Port $Port) {
        $processInfo = $null
        try { $processInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $processId) -ErrorAction Stop } catch {}
        if ($null -ne $processInfo -and [string]$processInfo.Name -eq 'ssh.exe') {
            Stop-NotifyProcessId -ProcessId $processId -Reason 'tunnel-process-scan' -AllowParentScopedSsh -AllowedParentProcessIds $wrapperIds
        }
        else {
            Stop-NotifyProcessId -ProcessId $processId -Reason 'tunnel-process-scan'
        }
    }
}

function Stop-NotifyWatchdogProcesses {
    foreach ($processId in Get-NotifyScriptProcessIds -ScriptName 'pi-notify-watchdog.ps1') {
        Stop-NotifyProcessId -ProcessId $processId -Reason 'watchdog-process-scan'
    }
}

function Stop-NotifyBrokerProcesses {
    foreach ($processId in Get-NotifyScriptProcessIds -ScriptName 'pi-notify-broker.ps1') {
        Stop-NotifyProcessId -ProcessId $processId -Reason 'broker-process-scan'
    }
    Remove-Item -LiteralPath (Join-Path $baseDir 'broker.pid') -Force -ErrorAction SilentlyContinue
}

function Start-NotifyBroker {
    $brokerScript = Join-Path $binDir 'pi-notify-broker.ps1'
    if (-not (Test-Path -LiteralPath $brokerScript)) {
        Write-Host 'skip broker start: script not found'
        return
    }
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $brokerEnabled = $true
    if ($cfg.PSObject.Properties['brokerEnabled']) {
        try { $brokerEnabled = [bool]$cfg.brokerEnabled } catch { $brokerEnabled = $true }
    }
    if (-not $brokerEnabled) {
        Write-Host 'skip broker start: brokerEnabled=false'
        return
    }
    $brokerCommand = ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}"' -f (Get-NotifyBridgePowerShellExe), $brokerScript, $configPath)
    Start-NotifyDetachedCommand -CommandLine $brokerCommand -Name 'broker'
    Write-Host 'broker started'
}

function Reset-NotifyLog {
    param(
        [string]$BaseDir,
        [string]$Name
    )

    $path = Join-Path $BaseDir ('logs\{0}' -f $Name)
    if (-not (Test-Path -LiteralPath $path)) { return }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $archive = Join-Path (Split-Path -Parent $path) ('{0}.{1}.log' -f $stem, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $path -Destination $archive -Force
    Write-Host ('archived {0} log: {1}' -f $stem, $archive)
}

function Clear-NotifyPopupRuntimeArtifacts {
    $logDir = Join-Path $baseDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { return }
    foreach ($pattern in @('popup-cache.json', 'activation-*.json', 'popup-live.*.json', 'popup-payload.json', 'popup-dedupe.json', 'popup-stdout.log', 'popup-stderr.log', 'popup-payload.*.json', 'popup-dedupe.*.json', 'popup-stdout.*.log', 'popup-stderr.*.log', 'popup.log', 'listener.log', 'activate.log', 'hotkey.log', 'broker.log')) {
        foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Pull) {
    Write-Host "[1/7] git pull..."
    $gitRoot = (& git -C $repoDir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
        throw ('git root detection failed for {0}' -f $repoDir)
    }
    $upstream = (& git -C $gitRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        git -C $gitRoot pull --ff-only
    }
    else {
        $branch = (& git -C $gitRoot branch --show-current 2>$null)
        if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }
        git -C $gitRoot pull --ff-only origin $branch
    }
    if ($LASTEXITCODE -ne 0) {
        throw ('git pull failed with exit code {0}' -f $LASTEXITCODE)
    }
}
else {
    Write-Host "[1/7] skip git pull (use -Pull to enable)"
}

Write-Host "[2/7] update config..."
$staleTokenTempFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'remote-windows-notify.*.json' -ErrorAction SilentlyContinue)
foreach ($staleTokenTempFile in $staleTokenTempFiles) {
    Remove-Item -LiteralPath $staleTokenTempFile.FullName -Force -ErrorAction SilentlyContinue
}
$existingCfg = $null
if (Test-Path -LiteralPath $configPath) {
    try { $existingCfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch { $existingCfg = $null }
}
$ensureArgs = @{
    ConfigPath = $configPath
    DisplayMode = $DisplayMode
    PopupTimeoutSeconds = $PopupTimeout
    PopupPlacement = $PopupPlacement
}
$shouldSetPort = $Port -gt 0 -and ($null -eq $existingCfg -or $null -eq $existingCfg.PSObject.Properties['port'] -or [int]$existingCfg.port -eq 23117 -or [int]$existingCfg.port -eq $Port)
if ($shouldSetPort) { $ensureArgs.Port = $Port }
$configObject = Ensure-NotifyBridgeConfig @ensureArgs
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
$normalizedPopupPlacement = if ([string]::IsNullOrWhiteSpace($PopupPlacement)) { 'cursor' } else { $PopupPlacement.Trim().ToLowerInvariant() }
if ($normalizedPopupPlacement -notin @('cursor', 'primary', 'right')) { $normalizedPopupPlacement = 'cursor' }
if ($cfg.PSObject.Properties['popupPlacement']) {
    $cfg.popupPlacement = $normalizedPopupPlacement
}
else {
    $cfg | Add-Member -NotePropertyName 'popupPlacement' -NotePropertyValue $normalizedPopupPlacement
}
$normalizedTunnelStartupDelay = 5
if ($cfg.PSObject.Properties['tunnelStartupDelaySeconds']) {
    if ([int]$cfg.tunnelStartupDelaySeconds -lt $normalizedTunnelStartupDelay) { $cfg.tunnelStartupDelaySeconds = $normalizedTunnelStartupDelay }
}
else {
    $cfg | Add-Member -NotePropertyName 'tunnelStartupDelaySeconds' -NotePropertyValue $normalizedTunnelStartupDelay
}
if ($Port -gt 0 -and (($null -eq $cfg.port) -or ([int]$cfg.port -eq 23117) -or ([int]$cfg.port -eq $Port))) {
    $cfg.port = $Port
    $cfg.localUrl = "http://127.0.0.1:$Port/notify"
    $cfg.remoteUrl = "http://127.0.0.1:$Port/notify"
}
$cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

Write-Host "[3/7] sync runtime files..."
New-Item -ItemType Directory -Force -Path $binDir, $piExtDir | Out-Null
$runtimeFiles = @(
    'NotifyBridge.Common.ps1',
    'notify-listener.ps1',
    'pi-notify-popup.ps1',
    'pi-notify-broker.ps1',
    'pi-notify-activate.ps1',
    'pi-notify-hotkey.ps1',
    'pi-notify-reverse-tunnel.ps1',
    'pi-notify-watchdog.ps1',
    'pi-notify-listener-runner.ps1',
    'pi-notify-restart-listener.ps1',
    'pi-notify-refresh.ps1',
    'pi-notify-check.ps1',
    'pi-notify-noop.ps1',
    'set-notify-mode.ps1',
    'register-toast-shortcut.py',
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
Copy-Item "$PSScriptRoot\remote-windows-notify.ts" "$piExtDir\remote-windows-notify.ts" -Force
$bundledWallpaperPath = Join-Path $binDir 'popup-wallpaper.png'
if ((Test-Path -LiteralPath $bundledWallpaperPath) -and ((-not $cfg.PSObject.Properties['popupWallpaperPath']) -or [string]::IsNullOrWhiteSpace([string]$cfg.popupWallpaperPath) -or -not (Test-Path -LiteralPath ([string]$cfg.popupWallpaperPath)))) {
    if ($cfg.PSObject.Properties['popupWallpaperPath']) { $cfg.popupWallpaperPath = $bundledWallpaperPath } else { $cfg | Add-Member -NotePropertyName 'popupWallpaperPath' -NotePropertyValue $bundledWallpaperPath }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
}
$hotkeyScript = Join-Path $binDir 'pi-notify-hotkey.ps1'
$popupHotkeyShortcutPath = Register-NotifyBridgePopupHotkeyShortcut -PowerShellExe (Get-NotifyBridgePowerShellExe) -HotkeyScript $hotkeyScript -ConfigPathValue $configPath -HotkeyValue ([string]$cfg.popupHotkey) -Enabled ([bool]$cfg.popupHotkeyEnabled)
Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\PiNotifyHotkey.vbs') -Force -ErrorAction SilentlyContinue
Write-Host ('Popup hotkey: {0} -> {1}' -f $cfg.popupHotkey, $popupHotkeyShortcutPath)
Clear-NotifyPopupRuntimeArtifacts

if ($SyncRemote -and -not $SkipRemoteSync) {
    Write-Host "[4/7] sync remote config..."
    $remoteHost = if ([string]::IsNullOrWhiteSpace([string]$cfg.remoteHostAlias)) { 'my' } else { [string]$cfg.remoteHostAlias }
    $sshExecutable = if ([string]::IsNullOrWhiteSpace([string]$cfg.sshExecutable)) { '' } else { [string]$cfg.sshExecutable }
    $installArgs = @{
        RemoteHostAlias = $remoteHost
        RemotePiDir = $RemotePiDir
        ConfigPath = $configPath
        ListenHost = [string]$cfg.listenHost
        Port = [int]$cfg.port
        Token = [string]$cfg.token
    }
    if (-not [string]::IsNullOrWhiteSpace($sshExecutable)) {
        $installArgs.SshExecutable = $sshExecutable
    }
    & (Join-Path $PSScriptRoot 'install-remote-windows-notify.ps1') @installArgs
    if ($LASTEXITCODE -ne 0) { throw ('remote sync failed on {0}' -f $remoteHost) }
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
}
else {
    Write-Host "[4/7] skip remote config sync (use -SyncRemote to enable)"
}

if ($SkipTunnel) {
    Write-Host "[5/7] keep existing reverse tunnel; restart watchdog around listener refresh (-SkipTunnel)"
    Stop-NotifyWatchdogProcesses
    Stop-NotifyBrokerProcesses
    Reset-NotifyLog -BaseDir $baseDir -Name 'watchdog.log'
    Reset-NotifyLog -BaseDir $baseDir -Name 'hotkey.log'
    Reset-NotifyLog -BaseDir $baseDir -Name 'broker.log'
}
else {
    Write-Host "[5/7] stop old tunnel/watchdog/broker..."
    Stop-NotifyPidFile -Path $tunnelPidPath -Reason 'tunnel-pid-file'
    Stop-NotifyTunnelProcesses -Port ([int]$cfg.port)
    Stop-NotifyWatchdogProcesses
    Stop-NotifyBrokerProcesses
    Reset-NotifyLog -BaseDir $baseDir -Name 'tunnel.log'
    Reset-NotifyLog -BaseDir $baseDir -Name 'watchdog.log'
    Reset-NotifyLog -BaseDir $baseDir -Name 'hotkey.log'
    Reset-NotifyLog -BaseDir $baseDir -Name 'broker.log'
}

Write-Host "[6/7] restart listener..."
$listenerLogDir = Join-Path $baseDir 'logs'
New-Item -ItemType Directory -Force -Path $listenerLogDir | Out-Null
$listenerStatusPath = Join-Path $listenerLogDir 'restart-listener.status.json'
$listenerRestartLogPath = Join-Path $listenerLogDir 'restart-listener.log'
Remove-Item -LiteralPath $listenerStatusPath -Force -ErrorAction SilentlyContinue
$listenerRestartCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" -TimeoutSeconds 60 -StatusPath "{3}" -LogPath "{4}"' -f (Get-NotifyBridgePowerShellExe), (Join-Path $binDir 'pi-notify-restart-listener.ps1'), $configPath, $listenerStatusPath, $listenerRestartLogPath)
Start-NotifyDetachedCommand -CommandLine $listenerRestartCommand -Name 'listener'
$listenerStatus = $null
$health = $null
for ($attempt = 1; $attempt -le 120; $attempt++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $listenerStatusPath) {
        try {
            $listenerStatus = Get-Content -LiteralPath $listenerStatusPath -Raw | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ([string]$listenerStatus.status -eq 'error') {
            throw ([string]$listenerStatus.message)
        }
        if ([string]$listenerStatus.status -eq 'ok') {
            try {
                $health = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$($cfg.port)/health" -TimeoutSec 2
                if ($health.StatusCode -eq 200) { break }
            }
            catch {
                $health = $null
            }
        }
    }
}
if ($null -eq $health) {
    if ($null -ne $listenerStatus -and -not [string]::IsNullOrWhiteSpace([string]$listenerStatus.message)) {
        throw ('Listener did not become healthy on port {0}: {1}' -f $cfg.port, $listenerStatus.message)
    }
    throw ('Listener did not become healthy on port {0}.' -f $cfg.port)
}
Write-Host ('listener healthy port={0}' -f $cfg.port)

if ($SkipTunnel) {
    Write-Host "[7/7] keep reverse tunnel; start broker/watchdog..."
    Start-NotifyBroker
    $watchdogCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" -StartupDelaySeconds 5' -f (Get-NotifyBridgePowerShellExe), (Join-Path $binDir 'pi-notify-watchdog.ps1'), $configPath)
    Start-NotifyDetachedCommand -CommandLine $watchdogCommand -Name 'watchdog'
}
else {
    Write-Host "[7/7] start reverse tunnel/broker/watchdog..."
    $tunnelCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" -TunnelStartupDelaySeconds 5' -f (Get-NotifyBridgePowerShellExe), (Join-Path $binDir 'pi-notify-reverse-tunnel.ps1'), $configPath)
    Start-NotifyDetachedCommand -CommandLine $tunnelCommand -Name 'tunnel'
    Start-NotifyBroker
    $watchdogCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" -StartupDelaySeconds 5' -f (Get-NotifyBridgePowerShellExe), (Join-Path $binDir 'pi-notify-watchdog.ps1'), $configPath)
    Start-NotifyDetachedCommand -CommandLine $watchdogCommand -Name 'watchdog'
}

$remoteTunnelHealth = $null
if ($SyncRemote -and -not $SkipRemoteSync -and -not $SkipTunnel) {
    $remoteHealthHost = if ([string]::IsNullOrWhiteSpace([string]$cfg.remoteHostAlias)) { 'my' } else { [string]$cfg.remoteHostAlias }
    $remoteHealthSsh = [string]$cfg.sshExecutable
    if ([string]::IsNullOrWhiteSpace($remoteHealthSsh)) {
        throw 'Configured sshExecutable is missing after remote sync.'
    }
    $remoteHealthScript = @"
import urllib.request
r = urllib.request.urlopen("http://127.0.0.1:$($cfg.port)/health", timeout=2)
print(r.read().decode())
"@
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        Start-Sleep -Seconds 1
        try {
            $output = $remoteHealthScript | & $remoteHealthSsh -T -o BatchMode=yes -o ConnectTimeout=10 $remoteHealthHost 'python3 -' 2>$null
            if ($LASTEXITCODE -eq 0 -and ([string]$output).Contains('"ok"')) {
                $remoteTunnelHealth = [string]$output
                break
            }
        }
        catch {
        }
    }
    if ($null -eq $remoteTunnelHealth) {
        Write-Warning ('Remote tunnel health is not ready yet on {0}; tunnel process will keep retrying.' -f $remoteHealthHost)
    }
    else {
        Write-Host ('Remote tunnel health: {0}' -f $remoteTunnelHealth)
    }
}

Write-Host "Done. health: $($health.Content)"
