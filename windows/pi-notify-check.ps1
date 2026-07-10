[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:USERPROFILE\.pi-notify\config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parentDir = Split-Path -Parent $PSScriptRoot
$repoDir = if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'remote-windows-notify.ts')) -and -not (Test-Path -LiteralPath (Join-Path $parentDir 'linux\extensions\remote-windows-notify.ts'))) {
    $PSScriptRoot
}
else {
    $parentDir
}
$configPath = [System.IO.Path]::GetFullPath($ConfigPath)
$runtimeBaseDir = Split-Path -Parent $configPath
$runtimeBin = Join-Path $runtimeBaseDir 'bin'

Write-Host ('repo: {0}' -f $repoDir)

$sourcePaths = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in @('.ps1', '.py', '.ts') })
$sourceText = @{}
foreach ($path in $sourcePaths) {
    $sourceText[$path.Name] = [System.IO.File]::ReadAllText($path.FullName, [System.Text.UTF8Encoding]::new($false))
}

Write-Host '[1/10] PowerShell syntax...'
foreach ($path in @($sourcePaths | Where-Object { $_.Extension -eq '.ps1' } | Sort-Object Name)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput([string]$sourceText[$path.Name], [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $errors | Format-List
        throw ('Syntax check failed: {0}' -f $path.FullName)
    }
    Write-Host ('OK {0}' -f $path.Name)
}

Write-Host '[2/10] PS1 ASCII source...'
foreach ($path in @($sourcePaths | Where-Object { $_.Extension -eq '.ps1' })) {
    $lineNumber = 0
    foreach ($line in [regex]::Split([string]$sourceText[$path.Name], "`r?`n")) {
        $lineNumber += 1
        foreach ($ch in $line.ToCharArray()) {
            if ([int][char]$ch -gt 127) {
                throw ('Non-ASCII PowerShell source: {0}:{1}' -f $path.FullName, $lineNumber)
            }
        }
    }
}
Write-Host 'OK no non-ascii ps1 source'

Write-Host '[3/10] PowerShell automatic variable hazards...'
$forbiddenLoopVar = 'foreach\s*\(\s*\$' + 'pid\b'
foreach ($path in @($sourcePaths | Where-Object { $_.Extension -eq '.ps1' })) {
    $lineNumber = 0
    foreach ($line in [regex]::Split([string]$sourceText[$path.Name], "`r?`n")) {
        $lineNumber += 1
        if ($line -match $forbiddenLoopVar) {
            throw ('PowerShell automatic variable loop hazard: {0}:{1}' -f $path.FullName, $lineNumber)
        }
    }
}
Write-Host 'OK no foreach $pid hazard'

Write-Host '[4/10] extension template drift...'
$linuxExtensionPath = Join-Path $repoDir 'linux\extensions\remote-windows-notify.ts'
$windowsExtensionPath = Join-Path $repoDir 'windows\remote-windows-notify.ts'
$flatExtensionPath = Join-Path $PSScriptRoot 'remote-windows-notify.ts'
if ((Test-Path -LiteralPath $linuxExtensionPath) -and (Test-Path -LiteralPath $windowsExtensionPath)) {
    $linuxExtension = [System.IO.File]::ReadAllText($linuxExtensionPath, [System.Text.UTF8Encoding]::new($false))
    $windowsExtension = [string]$sourceText['remote-windows-notify.ts']
    if ($linuxExtension -ne $windowsExtension) {
        throw 'Linux and Windows extension templates differ. Copy the canonical extension before shipping.'
    }
    if ($windowsExtension -notmatch 'getExtensionConfigPaths' -or $windowsExtension -notmatch 'fileURLToPath\(import\.meta\.url\)') {
        throw 'Extension template must discover remote-windows-notify.json relative to its installed path for custom -RemotePiDir.'
    }
    Write-Host 'OK extension templates match'
}
elseif (Test-Path -LiteralPath $flatExtensionPath) {
    $flatExtension = [string]$sourceText['remote-windows-notify.ts']
    if ($flatExtension -notmatch '__piRemoteWindowsNotifyRegistered' -or $flatExtension -match 'cachedConfigPromise' -or $flatExtension -notmatch '127\.0\.0\.1:23118/notify' -or $flatExtension -notmatch 'getExtensionConfigPaths' -or $flatExtension -notmatch 'fileURLToPath\(import\.meta\.url\)') {
        throw 'Flat extension template is stale.'
    }
    Write-Host 'OK flat extension template is current'
}
else {
    throw 'No remote-windows-notify.ts template found.'
}

$commonText = [string]$sourceText['NotifyBridge.Common.ps1']
$processText = [string]$sourceText['NotifyBridge.Process.ps1']
$remoteHelperText = [string]$sourceText['NotifyBridge.Remote.ps1']
$brokerText = [string]$sourceText['pi-notify-broker.ps1']
$popupText = [string]$sourceText['pi-notify-popup.ps1']
$refreshText = [string]$sourceText['pi-notify-refresh.ps1']
$windowsInstallText = [string]$sourceText['install-windows-autostart.ps1']
$restartText = [string]$sourceText['pi-notify-restart-listener.ps1']
$remoteInstallText = [string]$sourceText['install-remote-windows-notify.ps1']
$watchdogText = [string]$sourceText['pi-notify-watchdog.ps1']
$listenerText = [string]$sourceText['notify-listener.ps1']
$hotkeyText = [string]$sourceText['pi-notify-hotkey.ps1']
$activateText = [string]$sourceText['pi-notify-activate.ps1']
$setModeText = [string]$sourceText['set-notify-mode.ps1']
$shortcutHelperText = [string]$sourceText['register-toast-shortcut.py']
$runnerText = [string]$sourceText['pi-notify-listener-runner.ps1']
$tunnelText = [string]$sourceText['pi-notify-reverse-tunnel.ps1']
$linuxInstallText = [string]$sourceText['install-linux-autostart.ps1']
$autostartAllText = [string]$sourceText['install-autostart-all.ps1']
$checkText = [string]$sourceText['pi-notify-check.ps1']
if ($commonText -notmatch 'brokerEnabled' -or $commonText -notmatch 'brokerPort' -or $commonText -notmatch 'brokerStartupTimeoutMs' -or $commonText -notmatch 'brokerRequestTimeoutMs' -or $commonText -notmatch 'BrokerHealthUrl' -or $commonText -notmatch 'BrokerPopupUrl' -or $commonText -notmatch 'BrokerCloseUrl') {
    throw 'NotifyBridge config must persist stable broker defaults (brokerEnabled, brokerPort, brokerStartupTimeoutMs, brokerRequestTimeoutMs) and expose broker URLs.'
}
$hasPs5TokenRng = ($commonText -match 'RandomNumberGenerator\]::Create\(\)' -and $commonText -match '\.GetBytes\(\$buffer\)')
$hasModernTokenRng = ($commonText -match 'RandomNumberGenerator\]::Fill')
if (-not ($hasPs5TokenRng -or $hasModernTokenRng)) {
    throw 'Token generation must be compatible with Windows PowerShell 5.1/.NET Framework.'
}
$badSshFullPathPattern = 'GetFullPath\(\$' + 'SshExecutable\)'
$badSshTestPathPattern = 'Test-Path -LiteralPath \(Resolve-NotifyBridgeExecutableValue -Value \(\[string\]\$existing\[' + "'" + 'sshExecutable' + "'" + '\]\)\)'
if ($commonText -notmatch 'Resolve-NotifyBridgeExecutableValue' -or $commonText -notmatch 'Test-NotifyBridgeExecutableAvailable' -or $commonText -match $badSshFullPathPattern -or $commonText -match $badSshTestPathPattern -or $commonText -match '\$detectedSsh\s*=') {
    throw 'NotifyBridge config must honor provided sshExecutable before discovery and preserve bare command names like ssh.exe.'
}
if ($commonText -notmatch 'Set-NotifyBridgeActiveConfigPath' -or $commonText -notmatch 'Get-NotifyBridgeDefaultBaseDir' -or $commonText -notmatch 'TunnelStartupDelaySeconds[\s\S]{0,80}-ge 5' -or $commonText -notmatch 'tunnelStartupDelaySeconds[\s\S]{0,80}-ge 5') {
    throw 'NotifyBridge common config must derive instance base from ConfigPath and reject zero tunnel startup delay.'
}
$customProbeBase = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-configpath-probe-' + [guid]::NewGuid().ToString('N'))
$customProbeConfig = Join-Path $customProbeBase 'config.json'
try {
    . (Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1')
    . (Join-Path $PSScriptRoot 'NotifyBridge.Process.ps1')
    . (Join-Path $PSScriptRoot 'NotifyBridge.Remote.ps1')
    $probeConfig = Ensure-NotifyBridgeConfig -ConfigPath $customProbeConfig -Port 23119 -SshExecutable 'ssh.exe' -RemoteHostAlias 'probe' -TunnelStartupDelaySeconds 0
    if ((Get-NotifyBridgeBaseDir) -ne $customProbeBase -or (Get-NotifyBridgeBinDir) -ne (Join-Path $customProbeBase 'bin') -or (Get-NotifyBridgeLogDir) -ne (Join-Path $customProbeBase 'logs') -or [int]$probeConfig.TunnelStartupDelaySeconds -lt 5 -or [int]$probeConfig.PopupTimeoutSeconds -ne 1800) {
        throw 'ConfigPath probe failed.'
    }
    $reloadProbeConfig = Ensure-NotifyBridgeConfig -ConfigPath $customProbeConfig
    $reloadRaw = Get-Content -LiteralPath $customProbeConfig -Raw | ConvertFrom-Json
    if ([string]$reloadProbeConfig.SshExecutable -ne 'ssh.exe' -or [string]$reloadRaw.sshExecutable -ne 'ssh.exe') {
        throw 'Existing bare sshExecutable must survive reload from ConfigPath.'
    }

    $ownedPath = Join-Path $customProbeBase 'bin'
    $ownedCommand = 'powershell.exe -File "{0}"' -f (Join-Path $ownedPath 'notify-listener.ps1')
    $siblingCommand = 'powershell.exe -File "{0}"' -f (Join-Path (Join-Path ($customProbeBase + '-other') 'bin') 'notify-listener.ps1')
    if (-not (Test-NotifyBridgeCommandLineContainsPath -CommandLine $ownedCommand -Path $ownedPath) -or
        -not (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $ownedCommand -OwnedPaths @($customProbeConfig, $ownedPath, $customProbeBase)) -or
        (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $siblingCommand -OwnedPaths @($customProbeConfig, $ownedPath, $customProbeBase))) {
        throw 'Process helper instance path boundary probe failed.'
    }

    if ((Resolve-NotifyBridgeRemotePiDir -PathValue '~' -RemoteHome '/home/probe') -ne '/home/probe' -or
        (Resolve-NotifyBridgeRemotePiDir -PathValue '~/agent/' -RemoteHome '/home/probe/') -ne '/home/probe/agent' -or
        (Resolve-NotifyBridgeRemotePiDir -PathValue '/opt/pi/' -RemoteHome '/home/probe') -ne '/opt/pi' -or
        (Resolve-NotifyBridgeRemotePiDir -PathValue 'agent/' -RemoteHome '/home/probe') -ne '/home/probe/agent') {
        throw 'Remote Pi directory normalization probe failed.'
    }
    $quote = [string][char]39
    if ((ConvertTo-NotifyBridgeRemoteShellLiteral -Value 'path with space') -ne ($quote + 'path with space' + $quote) -or
        (ConvertTo-NotifyBridgeWindowsProcessArgument -Value 'path with space') -ne '"path with space"' -or
        (ConvertTo-NotifyBridgeWindowsProcessArgument -Value 'C:\Program Files\Pi\') -ne '"C:\Program Files\Pi\\"') {
        throw 'Remote helper argument quoting probe failed.'
    }
}
finally {
    if (Test-Path -LiteralPath $customProbeBase) { Remove-Item -LiteralPath $customProbeBase -Recurse -Force -ErrorAction SilentlyContinue }
    if (Get-Command Set-NotifyBridgeActiveConfigPath -ErrorAction SilentlyContinue) { Set-NotifyBridgeActiveConfigPath -ConfigPath $configPath | Out-Null }
}
if ($commonText -notmatch 'Join-NotifyBridgeProcessArguments' -or $commonText -notmatch 'ConvertTo-NotifyBridgeProcessArgument' -or $commonText -notmatch 'Clear-NotifyBridgePopupArtifacts' -or $commonText -notmatch 'popup-payload\.json' -or $commonText -notmatch 'popup-stdout\.log' -or $commonText -notmatch 'popup-stderr\.log') {
    throw 'Common helper must quote child PowerShell arguments and clean popup artifacts, including legacy exact artifact names.'
}
$badStartProcessArrayPattern = 'Start-' + 'Process[\s\S]{0,240}-ArgumentList\s+@\('
foreach ($path in @($sourcePaths | Where-Object { $_.Extension -eq '.ps1' })) {
    if ([string]$sourceText[$path.Name] -match $badStartProcessArrayPattern) {
        throw ('Unsafe child process argument array in {0}; use quoted single-string arguments.' -f $path.Name)
    }
}

if ($processText -notmatch 'function Start-NotifyBridgeDetachedCommand' -or
    $processText -notmatch 'function Test-NotifyBridgeCommandLineContainsPath' -or
    $processText -notmatch 'function Test-NotifyBridgeProcessOwnedByPaths' -or
    $processText -notmatch 'function Get-NotifyBridgeScriptProcessIds' -or
    $remoteHelperText -notmatch 'function Resolve-NotifyBridgeRemotePiDir' -or
    $remoteHelperText -notmatch 'function Resolve-NotifyBridgeWorkingSshExecutable' -or
    $remoteHelperText -notmatch 'function Copy-NotifyBridgeFileToRemotePath' -or
    $remoteHelperText -notmatch 'function Copy-NotifyBridgeTextToRemotePath') {
    throw 'Focused process and remote helper files must expose the shared runtime contracts.'
}

$duplicateProcessHelperPattern = 'function\s+(ConvertTo-NotifyProcessArgument|Join-NotifyProcessArguments|Start-NotifyDetachedCommand|Test-NotifyCommandLineContainsPath|Test-NotifyProcessOwnedByThisInstance|Get-NotifyScriptProcessIds|Get-NotifyProcessIds)\b'
foreach ($name in @('pi-notify-restart-listener.ps1', 'pi-notify-refresh.ps1', 'pi-notify-watchdog.ps1')) {
    if ([string]$sourceText[$name] -match $duplicateProcessHelperPattern) {
        throw ('Duplicate process helper remains in {0}: {1}' -f $name, $Matches[1])
    }
}
$duplicateRemoteHelperPattern = 'function\s+(ConvertTo-RemoteShellLiteral|Resolve-RemotePiDir|ConvertTo-WindowsProcessArgument|Test-NotifySshExecutable|Resolve-WorkingNotifySshExecutable|Copy-FileToRemotePath|Copy-TextToRemotePath)\b'
foreach ($name in @('install-remote-windows-notify.ps1', 'install-linux-autostart.ps1')) {
    if ([string]$sourceText[$name] -match $duplicateRemoteHelperPattern) {
        throw ('Duplicate remote helper remains in {0}: {1}' -f $name, $Matches[1])
    }
}
foreach ($helperName in @('NotifyBridge.Process.ps1', 'NotifyBridge.Remote.ps1')) {
    if ($refreshText -notmatch [regex]::Escape($helperName) -or
        $restartText -notmatch [regex]::Escape($helperName) -or
        $remoteInstallText -notmatch [regex]::Escape($helperName) -or
        $windowsInstallText -notmatch [regex]::Escape($helperName)) {
        throw ('Shared helper must be included in every runtime sync path: {0}' -f $helperName)
    }
}
for ($phase = 1; $phase -le 10; $phase++) {
    if ($checkText -notmatch [regex]::Escape(('[' + $phase + '/10]'))) {
        throw ('Check progress phase is missing: {0}/10' -f $phase)
    }
}
if ($checkText -match '\[[1-9]/9\]' -or ([regex]::Matches($checkText, 'ReadAllText\(\$path\.FullName')).Count -ne 1) {
    throw 'Check script must load static sources once and use consistent 10-phase progress labels.'
}

$deadFunctionPattern = 'function\s+(Protect-NotifyBrokerLiveValue|Get-NotifyBrokerSelectedTerminalTarget|Write-NotifyBrokerHttpResponse|Read-NotifyBrokerHttpRequest|Save-NotifyPopupDedupeState|Get-NotifyPopupPayloadPathFromCommandLine|Test-NotifyPathUnderDirectory)\b'
foreach ($name in @('pi-notify-broker.ps1', 'pi-notify-popup.ps1', 'notify-listener.ps1')) {
    if ([string]$sourceText[$name] -match $deadFunctionPattern) {
        throw ('Dead runtime helper remains in {0}: {1}' -f $name, $Matches[1])
    }
}

# Broker script assertions: syntax is covered by [1/10]; here we assert privacy,
# runtime-file coverage, and config defaults.
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'pi-notify-broker.ps1'))) {
    throw 'pi-notify-broker.ps1 must exist for low-latency broker path.'
}
if ($brokerText -notmatch 'System.Net.IPAddress\]::Loopback' -or $brokerText -notmatch '/health' -or $brokerText -notmatch '/popup' -or $brokerText -notmatch '/close') {
    throw 'Broker must bind loopback only and expose /health, /popup, /close endpoints.'
}
if ($brokerText -notmatch 'broker.pid' -or $brokerText -notmatch 'broker.log' -or $brokerText -notmatch 'Global\\PiNotifyBroker_') {
    throw 'Broker must write broker.pid/broker.log and use a singleton mutex.'
}
if ($brokerText -notmatch 'popup-live\.' -or $brokerText -notmatch 'brokerManaged\s*=\s*\$true' -or $brokerText -match 'protected(Host|Cwd|Tab)\s*=') {
    throw 'Broker-managed live-state files must avoid target-context DPAPI work; broker /activate-oldest and /close use in-memory popup state and popupId.'
}
# Privacy: broker logs must not include raw notification content or target context
$badBrokerLogPattern = ('broker-popup-start ' + 'title=') + '|' + ('broker-popup-start ' + 'body=') + '|' + ('broker-shown ' + 'title=') + '|' + 'sourceTabTitle="' + '|' + 'cwdBase="' + '|' + 'sessionName="' + '|' + 'windowTitle="' + '|' + 'tabName="' + '|' + 'broker-action activate host=' + '|' + 'broker-cache host="' + '|' + 'broker-keywords "'
if ($brokerText -match $badBrokerLogPattern) {
    throw 'Broker logs must not persist notification title/body text or raw target context.'
}
if ($brokerText -notmatch 'Get-NotifyBrokerContextFingerprint') {
    throw 'Broker must fingerprint target context in logs.'
}
if ($brokerText -notmatch 'WM_MOUSEACTIVATE' -or $brokerText -notmatch 'MA_NOACTIVATE' -or $brokerText -notmatch 'SetWindowPos' -or $brokerText -notmatch 'NotifyBrokerSwpShowNoActivate' -or $brokerText -match 'PreviousForegroundWindow' -or $popupText -notmatch 'WM_MOUSEACTIVATE' -or $popupText -notmatch 'MA_NOACTIVATE' -or $popupText -notmatch 'SetWindowPos' -or $popupText -notmatch 'NotifyPopupSwpShowNoActivate' -or $popupText -match 'previousForegroundWindow') {
    throw 'Popup windows must show with native SWP_NOACTIVATE and must not restore stale foreground windows.'
}
# Tab cache: conservative TTL and liveness validation before reuse
if ($brokerText -notmatch 'NotifyBrokerTabCacheTtlSeconds' -or $brokerText -notmatch 'Test-NotifyBrokerTabCacheEntryValid' -or $brokerText -notmatch 'NotifyBrokerTabCacheByTarget' -or $brokerText -notmatch 'Queue-NotifyBrokerActivation' -or $brokerText -notmatch 'GetWindowThreadProcessId') {
    throw 'Broker tab cache must use target-specific conservative TTL, liveness validation, and deferred activation before reuse.'
}
if ($brokerText -notmatch 'NotifyBrokerPopupMaxVisible' -or $brokerText -notmatch 'broker-popup-drop-overflow') {
    throw 'Broker must cap visible popup stack depth to avoid covering the mouse/caret area.'
}
if ($commonText -notmatch 'popupMaxVisible' -or $commonText -notmatch 'PopupMaxVisible') {
    throw 'Common config must expose popupMaxVisible so the visible popup cap can be tuned.'
}
if ($brokerText -notmatch '\$usedSlots = @\{\}' -or $brokerText -notmatch '\$reuseSlot = -1' -or $brokerText -notmatch 'StackIndex\s*=\s*\$StackIndex' -or $brokerText -match 'activeCount = @\(\$script:NotifyBrokerActivePopups\.Keys\)\.Count') {
    throw 'Broker popup stacking must track occupied slots and reuse the first free slot instead of deriving slot from active popup count.'
}
# Broker must be in refresh/autostart/restart runtime file lists
if ($refreshText -notmatch "'pi-notify-broker.ps1'" -or $windowsInstallText -notmatch "'pi-notify-broker.ps1'" -or $restartText -notmatch "'pi-notify-broker.ps1'" -or $remoteInstallText -notmatch "'pi-notify-broker.ps1'") {
    throw 'Broker script must be included in refresh/autostart/restart/remote-install runtime file lists.'
}
if ($refreshText -notmatch 'Stop-NotifyBrokerProcesses' -or $refreshText -notmatch 'Start-NotifyBroker' -or $refreshText -notmatch '\[int\]\$PopupTimeout\s*=\s*1800') {
    throw 'Refresh must stop and start the broker alongside listener/watchdog and default popup timeout to 30 minutes.'
}
if ($windowsInstallText -notmatch 'PiNotifyBroker.vbs' -or $windowsInstallText -notmatch '-STA') {
    throw 'Windows autostart must create a PiNotifyBroker.vbs launcher with -STA for the WinForms message loop.'
}
# Watchdog broker supervision and stale-listener fix
if ($watchdogText -notmatch 'Test-NotifyBrokerHealth' -or $watchdogText -notmatch 'NotifyWatchdogBrokerMisses\s*=\s*0' -or $watchdogText -notmatch 'broker-restart-requested') {
    throw 'Watchdog must supervise broker health and restart it when missing or unhealthy.'
}
if ($watchdogText -notmatch 'NotifyWatchdogHotkeyMisses\s*=\s*0' -or $watchdogText -notmatch 'stale-hotkey' -or $watchdogText -notmatch 'pi-notify-hotkey.ps1') {
    throw 'Watchdog must supervise the resident hotkey worker and restart it when missing.'
}
if ($watchdogText -notmatch 'if \(\$listenerOk\)' -or $watchdogText -notmatch '\$duplicateListener') {
    throw 'Watchdog must tolerate pid-file/process-shape mismatch when listener /health is OK to avoid false stale-listener restarts.'
}
# Listener broker delegation and fallback
if ($listenerText -notmatch 'Invoke-NotifyBrokerPopup' -or $listenerText -notmatch 'Start-NotifyPopupProcess' -or $listenerText -notmatch 'broker-unavailable fallback=popup-process' -or $listenerText -notmatch 'broker-post-failed fallback=popup-process' -or $listenerText -notmatch 'Get-NotifyBrokerProcessIds' -or $listenerText -notmatch 'broker-start-skip existing') {
    throw 'Listener must prefer broker for popup-focus, avoid duplicate broker starts, and fall back to pi-notify-popup.ps1 process on bounded failure.'
}
if ($listenerText -notmatch 'Dictionary\[string,string\][\s\S]{0,120}OrdinalIgnoreCase' -or ([regex]::Matches($brokerText, 'Dictionary\[string,string\][\s\S]{0,120}OrdinalIgnoreCase')).Count -lt 1) {
    throw 'Listener and broker HTTP parsers must treat headers as case-insensitive so Node fetch lowercase content-length is honored.'
}
if ($listenerText -notmatch 'TcpClient' -or $listenerText -notmatch 'BeginConnect' -or $listenerText -notmatch 'Content-Length: \$\(\$bodyBytes\.Length\)' -or $listenerText -notmatch 'broker-post-accepted-no-response' -or ([regex]::Matches($hotkeyText, 'ContentLength\s*=\s*\$closeBytes\.Length')).Count -lt 2) {
    throw 'Broker popup/close POST requests must use bounded loopback POSTs with Content-Length and avoid false fallback when the broker accepts but responds slowly.'
}
if ($listenerText -notmatch 'Invoke-NotifyBrokerPopup[^\r\n]+-StackIndex -1') {
    throw 'Listener must let the broker allocate popup stack slots; otherwise broker-managed popups overlap at slot 0.'
}
# Hotkey broker compatibility and resident registration
if ($hotkeyText -notmatch 'brokerManaged' -or $hotkeyText -notmatch 'BrokerCloseUrl' -or $hotkeyText -notmatch '"activate":true' -or $hotkeyText -notmatch 'pi-notify-broker.ps1' -or $hotkeyText -notmatch '-not \$brokerManaged') {
    throw 'Hotkey must recognize broker-managed popups, including popupId-only broker live-state, and activate/close them via broker /close without killing the broker.'
}
if ($brokerText -notmatch 'Set-NotifyBrokerPopupActivating' -or $brokerText -notmatch '0x8df3' -or $brokerText -notmatch 'broker-activation-feedback' -or $brokerText -notmatch 'FormToClose') {
    throw 'Broker activation must give immediate popup feedback and close the feedback card after focus activation finishes.'
}
if ($brokerText -notmatch '/activate-oldest' -or $brokerText -notmatch 'Invoke-NotifyBrokerOldestPopupActivation' -or $hotkeyText -notmatch 'Invoke-NotifyHotkeyBrokerActivateOldest' -or $hotkeyText -notmatch 'TcpClient' -or $hotkeyText -notmatch 'BeginConnect') {
    throw 'Hotkey must prefer bounded TcpClient broker /activate-oldest so Alt+L avoids popup-live file scan on the fast path.'
}
if ($brokerText -notmatch 'Queue-NotifyBrokerPrewarm' -or $brokerText -notmatch 'Update-NotifyBrokerTabCacheForTarget' -or $brokerText -notmatch 'broker-prewarm-cache-updated' -or $brokerText -notmatch 'broker-prewarm-skip recent-scan' -or $brokerText -notmatch 'broker-prewarm-dedupe' -or $brokerText -notmatch 'broker-prewarm-skip closed-popup' -or $brokerText -notmatch 'NotifyBrokerPrewarmDelayMs\s*=\s*10000') {
    throw 'Broker must prewarm target tab cache after popup display while delaying/throttling repeated expensive scans and skipping closed popups.'
}
if ($brokerText -notmatch 'Get-NotifyBrokerWallpaperCardImage' -or $brokerText -notmatch 'broker-wallpaper-card-rendered' -or $brokerText -notmatch 'DrawImageUnscaled' -or $brokerText -notmatch 'Get-NotifyBrokerWallpaperCardImage -Width 420 -Height 154') {
    throw 'Broker popup paint must use startup-warmed cached card-size wallpaper rendering instead of per-paint high-quality scaling.'
}
if ($brokerText -notmatch 'broker-client-disconnect stage=response') {
    throw 'Broker HTTP listener must treat client-disconnect response writes as benign instead of noisy bg errors.'
}
if ($hotkeyText -notmatch 'RegisterHotKey' -or $hotkeyText -notmatch 'Start-NotifyHotkeyResident' -or $hotkeyText -notmatch 'MOD_NOREPEAT' -or $hotkeyText -notmatch 'ConvertTo-NotifyHotkeyRegistration') {
    throw 'Hotkey must run as a resident RegisterHotKey worker so single-modifier shortcuts like Alt+P work reliably.'
}
if ($hotkeyText -notmatch '0xDB' -or $hotkeyText -notmatch '\$requiresShift' -or $hotkeyText -notmatch 'resident-register' -or $hotkeyText -notmatch 'resident-fired') {
    throw 'Hotkey parser must support Ctrl+{ by registering Ctrl+Shift+[ / VK_OEM_4 plus a Ctrl+[ alias.'
}
if ($refreshText -notmatch 'PiNotifyHotkey\.vbs' -or $refreshText -notmatch 'Start-NotifyHotkey' -or $refreshText -notmatch 'Stop-NotifyHotkeyProcesses' -or $refreshText -match 'Register-NotifyBridgePopupHotkeyShortcut') {
    throw 'Refresh must install/start the resident hotkey worker and must not rely on Start Menu shortcut hotkeys.'
}
Write-Host 'OK broker runtime, privacy, supervision, and fallback safeguards'
if ($listenerText -notmatch 'Join-NotifyBridgeProcessArguments' -or $listenerText -match 'RedirectStandardOutput\s+\$popupStdoutLogPath' -or $listenerText -match 'popup-stdout\.\{0\}' -or $listenerText -match 'targetKey\s*=\s*\$targetKey' -or $listenerText -match 'popup-[^\r\n]+targetKey=' -or $listenerText -match '\''-Title\'', \$Title' -or $listenerText -match '\''-Body\'', \$Body' -or $listenerText -notmatch 'PI_NOTIFY_TITLE' -or $listenerText -notmatch 'PI_NOTIFY_BODY' -or $listenerText -notmatch 'PI_NOTIFY_CWD_BASE' -or $listenerText -notmatch 'PI_NOTIFY_SESSION_NAME') {
    throw 'Popup launch must quote paths, avoid per-popup stdout/stderr files, and avoid storing/logging raw target keys or title/body/context in payload files or command lines.'
}
if ($popupText -notmatch 'PI_NOTIFY_TITLE' -or $popupText -notmatch 'PI_NOTIFY_BODY' -or $popupText -notmatch 'PI_NOTIFY_CWD_BASE' -or $popupText -notmatch 'PI_NOTIFY_SESSION_NAME' -or $popupText -match "PSObject.Properties\['title'\]" -or $popupText -match "PSObject.Properties\['body'\]" -or $popupText -match "PSObject.Properties\['cwdBase'\]" -or $popupText -match "PSObject.Properties\['tabTitle'\]" -or $popupText -match "PSObject.Properties\['sessionName'\]") {
    throw 'Popup process must read sensitive notification text/context from child environment, not disk payload.'
}
if ($popupText -match 'sanitizedPayload' -or $popupText -match 'WriteAllText\(\$PayloadPath' -or $popupText -match 'Remove-Item -LiteralPath \$script:NotifyPopupDedupePath') {
    throw 'Popup process must avoid creating live payload/dedupe artifacts; listener supplies non-sensitive metadata via command line.'
}
if ($popupText -notmatch 'Get-NotifyPopupContextFingerprint' -or $popupText -match 'popup-cache host="' -or $popupText -match 'popup-cache .*cwdBase=' -or $popupText -match 'popup-window title="' -or $popupText -match 'popup-tab .*name="' -or $popupText -match 'popup-focus-best windowTitle=' -or $popupText -match 'popup-initial-captured windowTitle=' -or $popupText -match 'popup-keywords "\{0\}"' -or $popupText -match 'popup-action activate host=') {
    throw 'Popup cache/logs must persist only fingerprints/counts for cwd/tab/window/keyword context.'
}
if ($popupText -match 'host\s*=\s*\$TargetHostValue' -or $popupText -match 'cwdBase\s*=\s*\$CwdBaseValue' -or $popupText -match 'windowTitle\s*=\s*\$WindowTitle' -or $popupText -match 'tabTitle\s*=\s*\$TabTitle') {
    throw 'Popup cache must not persist raw host/cwd/window/tab context.'
}
if ($popupText -match 'WriteAllText\(\$PayloadPath' -or $popupText -match 'popup-dedupe\.\{0\}\.json' -or $popupText -match 'popup-payload-read-error') {
    throw 'Live popup processes must not leave payload/dedupe JSON artifacts; use listener-owned memory and non-sensitive command-line metadata.'
}
if ($popupText -notmatch 'popup-live\.\{0\}\.json' -or $popupText -notmatch 'protectedHost' -or $popupText -notmatch 'protectedCwd' -or $popupText -notmatch 'protectedTab' -or $hotkeyText -notmatch 'Unprotect-NotifyHotkeyValue' -or $hotkeyText -match 'Write-NotifyHotkeyLog[^\r\n]*TargetHost' -or $hotkeyText -match 'Write-NotifyHotkeyLog[^\r\n]*CwdBase' -or $hotkeyText -match 'Write-NotifyHotkeyLog[^\r\n]*TabTitle') {
    throw 'Popup hotkey live state must store DPAPI-protected target context and hotkey logs must not persist raw target context.'
}
$badListenerNotificationLogPattern = ('notify ' + 'title=') + '|' + ('system-toast ' + 'title=') + '|' + ('notify-drop missing-target-metadata ' + 'title=') + '|' + ('popup-launch ' + 'title=') + '|' + ('popup-pid .*target' + 'Key') + '|' + ('popup-launch ' + 'focusTarget=') + '|' + ('notify-dedup .*focusTarget=') + '|' + ('notify focusTarget=') + '|' + 'sessionName='
$badPopupNotificationLogPattern = ('popup-start ' + 'title=') + '|' + ('popup-' + 'action .*' + 'tit' + 'le=') + '|' + ('popup-drop missing-target-metadata ' + 'title=') + '|' + ('popup-dedup drop-imprecise ' + 'title=') + '|' + 'sourceTabTitle="' + '|' + 'cwdBase="' + '|' + 'windowTitle="' + '|' + 'tabTitle="' + '|' + 'keywords="' + '|' + 'name="'
$badActivateNotificationLogPattern = 'activate-target host=' + '|' + 'activate-focus-miss .*host='
if ($listenerText -match $badListenerNotificationLogPattern -or $popupText -match $badPopupNotificationLogPattern -or $activateText -match $badActivateNotificationLogPattern) {
    throw 'Listener/popup/activate logs must not persist notification title/body text or raw target context.'
}
if ($activateText -notmatch 'Get-NotifyActivateFingerprint \$targetHost' -or $activateText -match 'activate-target host="' -or $activateText -match 'activate-focus-miss .*host="') {
    throw 'Activate script must log target host only as a fingerprint.'
}
if ($listenerText -notmatch '\$maxBodyBytes\s*=\s*65536' -or $listenerText -notmatch '\$contentLength -gt \$maxBodyBytes' -or $listenerText -notmatch 'HTTP request body too large') {
    throw 'Listener Read-HttpRequest must cap request bodies to avoid memory/connection abuse.'
}
if ($listenerText -match "'host=' \+ \[Uri\]::EscapeDataString" -or $listenerText -match "'cwdBase=' \+ \[Uri\]::EscapeDataString" -or $listenerText -match "'tabTitle=' \+ \[Uri\]::EscapeDataString" -or $listenerText -match '''-ConfigPath'', \$ConfigPath,\s*\r?\n\s*\$LaunchUri' -or $listenerText -notmatch 'PI_NOTIFY_FOCUS_TARGET' -or $listenerText -notmatch 'PI_NOTIFY_CWD_BASE' -or $listenerText -notmatch 'PI_NOTIFY_TAB_TITLE' -or $listenerText -notmatch 'Save-NotifyToastActivationState' -or $listenerText -notmatch "SetAttribute\('activationType', 'protocol'\)" -or $listenerText -notmatch 'ProtectedData\]::Protect' -or $listenerText -notmatch 'activation-\{0\}\.json') {
    throw 'System-toast activation must not persist raw host/cwd/tab in launch URI or activation command line; use protocol activationType, protected activation cache, and child environment.'
}
if ($listenerText -notmatch 'Get-NotifyCommandLineArgument' -or $listenerText -notmatch "Name 'ConfigPath'" -or $listenerText -notmatch "Name 'TargetFingerprint'" -or $listenerText -notmatch "Name 'StackIndex'" -or $listenerText -notmatch 'GetFullPath\(\$popupConfigPath\)\.Equals' -or $listenerText -match 'popup-payload\.\{0\}\.json') {
    throw 'Popup process scans must be limited by matching ConfigPath and non-sensitive TargetFingerprint/StackIndex command-line metadata, without live payload files.'
}
if ($listenerText -notmatch 'NotifyActivationCleanupTimers' -or $listenerText -notmatch 'TimerCallback' -or $listenerText -notmatch '\[TimeSpan\]::FromMinutes\(10\)' -or $listenerText -match 'Register-ObjectEvent' -or $listenerText -match 'system-toast-activation-events-unavailable') {
    throw 'System-toast activation must use protocol activation plus bounded cache timers; do not attempt unsupported PS5 WinRT event subscriptions.'
}
if ($activateText -notmatch 'Resolve-NotifyActivationState' -or $activateText -notmatch 'ProtectedData\]::Unprotect' -or $activateText -notmatch 'Get-NotifyQueryValue -ParsedUri \$parsedUri -Name ''id''' -or $activateText -notmatch '\$keywords = @\(\$tabTitle, \$cwdBase, \$targetHost\) \| Where-Object') {
    throw 'Activate script must resolve nonce-only system-toast activation ids and filter empty focus keywords before UI Automation binding.'
}
if ($commonText -notmatch 'function Register-NotifyBridgeSystemToastSupport' -or $commonText -notmatch 'Register-NotifyBridgeProtocolHandler' -or $commonText -notmatch 'Register-NotifyBridgeToastShortcut' -or $commonText -notmatch 'SHGetPropertyStoreFromParsingName' -or $commonText -notmatch 'New-Object -ComObject WScript.Shell' -or $commonText -notmatch 'Pi Remote\.lnk' -or $commonText -match 'Get-Command python') {
    throw 'Common must expose one shared setup path for system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
if ($remoteInstallText -notmatch 'Register-NotifyBridgeSystemToastSupport -ConfigPathValue \$config\.ConfigPath' -or $remoteInstallText -notmatch 'Toast link' -or $remoteInstallText -notmatch 'Click URI') {
    throw 'Fresh/manual remote installer must register system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
if ($windowsInstallText -notmatch 'Register-NotifyBridgeSystemToastSupport -ConfigPathValue \$config\.ConfigPath' -or $windowsInstallText -notmatch 'Toast link' -or $windowsInstallText -notmatch 'Click URI') {
    throw 'Windows autostart installer must register system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
$setModeRegisterIndex = $setModeText.IndexOf('Register-NotifyBridgeSystemToastSupport -ConfigPathValue $config.ConfigPath')
$setModeRestartIndex = $setModeText.IndexOf('if ($RestartListener)')
if ($setModeRegisterIndex -lt 0 -or $setModeRestartIndex -lt 0 -or $setModeRegisterIndex -gt $setModeRestartIndex -or $setModeText -match 'register-toast-shortcut\.py.*try') {
    throw 'set-notify-mode must register system-toast protocol/shortcut support even when -RestartListener:$false is used.'
}
if ($refreshText -notmatch 'Clear-NotifyPopupRuntimeArtifacts' -or $refreshText -notmatch 'activation-\*\.json' -or $refreshText -notmatch 'popup-live\.\*\.json' -or $refreshText -notmatch 'popup-payload\.json' -or $refreshText -notmatch 'popup-dedupe\.json' -or $refreshText -notmatch 'popup-stdout\.log' -or $refreshText -notmatch 'popup-stderr\.log' -or $refreshText -notmatch 'popup-payload\.\*\.json' -or $refreshText -notmatch 'popup-dedupe\.\*\.json' -or $refreshText -notmatch 'popup-stdout\.\*\.log' -or $refreshText -notmatch 'popup-stderr\.\*\.log' -or $refreshText -notmatch 'listener\.log' -or $refreshText -notmatch 'popup\.log' -or $refreshText -notmatch 'activate\.log' -or $refreshText -notmatch 'broker\.log') {
    throw 'Refresh must clear stale activation cache, popup payload/dedupe/stdout/stderr artifacts, including legacy exact names, and old notification-content logs.'
}
if ($restartText -notmatch 'Sync-LocalRuntimeFiles' -or $restartText -notmatch 'notify-listener\.ps1' -or $restartText -notmatch 'pi-notify-listener-runner\.ps1' -or $restartText -notmatch 'popup-wallpaper\.png' -or $restartText -notmatch 'NotifyBridge\.Process\.ps1' -or $restartText -notmatch 'Test-NotifyBridgeProcessOwnedByPaths' -or $restartText -notmatch 'Get-NotifyBridgeScriptProcessIds' -or $restartText -notmatch 'skip unowned listener process' -or $restartText -notmatch 'Split-Path -Parent \$ConfigPath' -or $restartText -match '\$baseDir = "\$env:USERPROFILE\\.pi-notify"') {
    throw 'Restart listener must bootstrap required runtime files and derive instance base from ConfigPath.'
}
$refreshHasWatchdogDelay = ($refreshText -match "'-StartupDelaySeconds', '5'" -or $refreshText -match '-StartupDelaySeconds 5')
$refreshHasTunnelDelay = ($refreshText -match "'-TunnelStartupDelaySeconds', '5'" -or $refreshText -match '-TunnelStartupDelaySeconds 5')
if ($refreshText -notmatch '\[string\]\$ConfigPath' -or $refreshText -notmatch 'NotifyBridge\.Process\.ps1' -or $refreshText -notmatch 'Test-NotifyBridgeProcessOwnedByPaths' -or $refreshText -notmatch 'Get-NotifyBridgeScriptProcessIds' -or $refreshText -notmatch 'skip unowned process' -or $refreshText -notmatch 'AllowParentScopedSsh' -or $refreshText -notmatch 'AllowedParentProcessIds' -or $refreshText -notmatch 'ParentProcessId' -or $refreshText -match "Name -ne 'ssh\.exe'" -or $refreshText -notmatch '\$wrapperIds -contains \$_.ParentProcessId' -or $refreshText -notmatch 'keep existing reverse tunnel; restart watchdog' -or -not $refreshHasWatchdogDelay -or -not $refreshHasTunnelDelay -or $refreshText -match '\$baseDir = "\$env:USERPROFILE\\.pi-notify"') {
    throw 'Refresh must derive instance base from ConfigPath, scope ssh by wrapper parent, skip unowned pid-file PIDs, and use nonzero startup delays.'
}
if ($runnerText -match 'Split-Path -Parent \$PSScriptRoot' -or $runnerText -notmatch 'Get-NotifyBridgeBaseDir' -or $runnerText -notmatch 'Set-NotifyBridgeActiveConfigPath') {
    throw 'Listener runner must write listener.pid under ConfigPath-derived Get-NotifyBridgeBaseDir, not relative to script path.'
}
if ($watchdogText -match "python3? - <<'PY'" -or $watchdogText -notmatch 'timeout 8s python3 -c' -or $watchdogText -notmatch 'ConnectTimeout=5' -or $watchdogText -notmatch 'ServerAliveInterval=2' -or $watchdogText -notmatch 'WaitForExit\(12000\)' -or $watchdogText -notmatch 'HTTP\\s\+200' -or $watchdogText -notmatch 'PiNotifyWatchdog_' -or $watchdogText -notmatch 'watchdog\.pid' -or $watchdogText -notmatch 'Merge-NotifyProcessIds' -or $watchdogText -notmatch 'NotifyBridge\.Process\.ps1' -or $watchdogText -notmatch 'Test-NotifyBridgeProcessOwnedByPaths' -or $watchdogText -notmatch 'Get-NotifyBridgeScriptProcessIds' -or $watchdogText -notmatch 'Test-NotifyProcessSafeToStop' -or $watchdogText -notmatch 'skip-unowned-taskkill' -or $watchdogText -notmatch 'NotifyWatchdogListenerMisses' -or $watchdogText -notmatch 'missingOwnedTunnel' -or $watchdogText -notmatch 'stale-owned-tunnel' -or $watchdogText -notmatch '\@\(\$tunnelPids\)\.Count -ne 1 -or \@\(\$sshPids\)\.Count -ne 1' -or $watchdogText -notmatch '\@\(\$tunnelPids\) -contains \$_\.ParentProcessId' -or $watchdogText -match '\$directListenerPids\s*\+\s*\$listenerRunnerPids' -or $watchdogText -match '\$tunnelPids\s*\+\s*\$sshPids') {
    throw 'Watchdog must use bounded python3 remote health, singleton mutex/pid guard, safe process-id merging, instance filtering, grace misses, parent-scoped ssh matching, and repair missing owned tunnel processes even if remote health passes.'
}
if ($tunnelText -notmatch 'ConnectTimeout=10') {
    throw 'Reverse tunnel must use ConnectTimeout to avoid hanging on bad SSH paths.'
}
$badTempConfigPathPattern = '\$temp' + 'ConfigPath'
$badTempConfigNamePattern = 'remote-windows-notify\.' + '\{0\}' + '\.json'
if ($remoteInstallText -notmatch 'Copy-NotifyBridgeTextToRemotePath' -or $remoteInstallText -match $badTempConfigPathPattern -or $remoteInstallText -match $badTempConfigNamePattern) {
    throw 'Remote installer must not write token-bearing config JSON to local temp files.'
}
if ($remoteInstallText -notmatch 'staleTokenTempFiles' -or $refreshText -notmatch 'staleTokenTempFiles') {
    throw 'Remote install and refresh must clean stale local token temp files from older versions.'
}
$localTokenTempFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'remote-windows-notify.*.json' -ErrorAction SilentlyContinue)
if ($localTokenTempFiles.Count -gt 0) {
    throw ('Local token temp files remain in TEMP: {0}' -f (($localTokenTempFiles | Select-Object -ExpandProperty Name) -join ', '))
}
if ($remoteInstallText -notmatch '\$runtimeFiles' -or $remoteInstallText -notmatch 'pi-notify-restart-listener\.ps1' -or $remoteInstallText -notmatch 'pi-notify-listener-runner\.ps1') {
    throw 'First-time remote installer must copy local runtime files needed by its printed next-step start command.'
}
if ($remoteInstallText -notmatch [regex]::Escape("Join-Path `$PSScriptRoot 'pi-notify-restart-listener.ps1'") -or $remoteInstallText -match [regex]::Escape('.\scripts\pi-notify\pi-notify-restart-listener.ps1') -or $remoteInstallText -match [regex]::Escape('.\windows\pi-notify-restart-listener.ps1')) {
    throw 'Remote installer printed next-step command must use the actual script directory, not a cwd-dependent relative path.'
}
if ($remoteInstallText -notmatch [regex]::Escape("Join-Path `$binDir 'pi-notify-restart-listener.ps1'") -or $remoteInstallText -match '\\\"\$binDir') {
    throw 'Remote installer runtime-bin fallback command must print a valid quoted path without backslash escaping.'
}
$badRemoteUmask = 'umask 0' + '22'
$badLinuxTempConfigPattern = '\$temp' + 'Config'
if ($remoteHelperText -match $badRemoteUmask -or $remoteHelperText -notmatch 'umask 077' -or $remoteHelperText -notmatch '\[string\]\$Mode = ''0600''' -or $remoteInstallText -notmatch "-Mode '0600'" -or $remoteInstallText -notmatch 'remoteManagedConfigPath' -or $remoteInstallText -notmatch 'stat -c' -or $linuxInstallText -notmatch 'Copy-NotifyBridgeTextToRemotePath' -or $linuxInstallText -match $badLinuxTempConfigPattern -or $linuxInstallText -notmatch 'install -m 0600 "\$managed_dir/remote-windows-notify\.json"' -or $linuxInstallText -notmatch "-Mode '0600'") {
    throw 'Remote token config files must be uploaded/installed with umask 077 and mode 0600.'
}
if ($refreshText -match 'origin master' -or $refreshText -notmatch 'rev-parse --abbrev-ref --symbolic-full-name' -or $refreshText -notmatch 'branch --show-current') {
    throw 'Refresh -Pull must detect current branch/upstream instead of hard-coding origin master.'
}
if ($refreshText -notmatch '\$runtimeFiles' -or $refreshText -notmatch 'GetFullPath\(\$source\)' -or $refreshText -notmatch 'GetFullPath\(\$destination\)') {
    throw 'Refresh runtime sync must use a runtime file list with same-path skip so it works from the runtime bin.'
}
foreach ($requiredRuntimeName in @('NotifyBridge.Process.ps1', 'NotifyBridge.Remote.ps1', 'remote-windows-notify.ts', 'popup-wallpaper.png', 'install-remote-windows-notify.ps1', 'install-linux-autostart.ps1', 'install-windows-autostart.ps1', 'install-autostart-all.ps1', 'pi-notify-check.ps1', 'pi-notify-hotkey.ps1', 'pi-notify-broker.ps1')) {
    if ($refreshText -notmatch [regex]::Escape($requiredRuntimeName) -or $autostartAllText -match 'unused-never-match') {
        throw ('Refresh runtime sync must copy required file: {0}' -f $requiredRuntimeName)
    }
    if ($windowsInstallText -notmatch [regex]::Escape($requiredRuntimeName)) {
        throw ('Windows autostart installer must copy required runtime file: {0}' -f $requiredRuntimeName)
    }
}
$runtimeBin = Join-Path $runtimeBaseDir 'bin'
if (Test-Path -LiteralPath $runtimeBin) {
    foreach ($requiredRuntimeName in @('NotifyBridge.Process.ps1', 'NotifyBridge.Remote.ps1', 'remote-windows-notify.ts', 'popup-wallpaper.png', 'install-remote-windows-notify.ps1', 'install-linux-autostart.ps1', 'install-windows-autostart.ps1', 'install-autostart-all.ps1', 'pi-notify-check.ps1', 'pi-notify-hotkey.ps1', 'pi-notify-broker.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtimeBin $requiredRuntimeName))) {
            throw ('Runtime bin is missing required file: {0}' -f $requiredRuntimeName)
        }
    }
}
if ($remoteInstallText -notmatch 'NotifyBridge\.Remote\.ps1' -or $remoteInstallText -notmatch 'Resolve-NotifyBridgeRemotePiDir' -or $remoteInstallText -notmatch 'ConvertTo-NotifyBridgeRemoteShellLiteral' -or $remoteInstallText -notmatch 'Copy-NotifyBridgeFileToRemotePath') {
    throw 'Remote installer must resolve -RemotePiDir and upload through shell-quoted remote paths.'
}
if ($refreshText -notmatch '\[string\]\$RemotePiDir' -or $refreshText -notmatch 'install-remote-windows-notify\.ps1' -or $refreshText -notmatch 'RemotePiDir = \$RemotePiDir') {
    throw 'Refresh -SyncRemote must accept and pass -RemotePiDir to the remote installer.'
}
if ($autostartAllText -notmatch '\[string\]\$RemotePiDir' -or $autostartAllText -notmatch '\$linuxArgs\.RemotePiDir = \$RemotePiDir') {
    throw 'One-shot autostart installer must accept and pass -RemotePiDir to Linux autostart.'
}
foreach ($installerText in @($remoteInstallText, $linuxInstallText, $refreshText)) {
    if ($installerText -match '&\s+ssh\b' -or $installerText -match '&\s+scp\b' -or $installerText -match "FileName\s*=\s*'ssh'" -or $installerText -match "\{\s*'ssh'\s*\}") {
        throw 'Remote installers and refresh must use configured sshExecutable, not bare ssh/scp.'
    }
}
if ($refreshText -notmatch 'Configured sshExecutable is missing after remote sync' -or $refreshText -notmatch 'Get-Content \$configPath -Raw \| ConvertFrom-Json') {
    throw 'Refresh remote health must reload and require the persisted configured sshExecutable after remote sync.'
}
if ($remoteInstallText -notmatch 'Resolve-NotifyBridgeWorkingSshExecutable' -or $linuxInstallText -notmatch 'Resolve-NotifyBridgeWorkingSshExecutable' -or $remoteInstallText -notmatch 'Ensure-NotifyBridgeConfig -ConfigPath \$config\.ConfigPath -SshExecutable \$sshExe' -or $linuxInstallText -notmatch 'Ensure-NotifyBridgeConfig -ConfigPath \$config\.ConfigPath -SshExecutable \$sshExe' -or $remoteHelperText -notmatch 'Test-NotifyBridgeExecutableAvailable -Value \$SshPath' -or $remoteHelperText -match '\$SshPath -ne ''ssh\.exe''') {
    throw 'Remote installers must probe configured sshExecutable, preserve PATH/bare commands, persist the selected working ssh, and fall back only when needed.'
}
if ($linuxInstallText -match '/etc/systemd/system' -or $linuxInstallText -match 'User=root' -or $linuxInstallText -notmatch 'systemctl --user' -or $linuxInstallText -notmatch 'crontab' -or $linuxInstallText -notmatch '\.config/systemd/user') {
    throw 'Linux autostart must use user-level systemd or user crontab fallback, not root /etc systemd.'
}
$repoRootForIggTools = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$iggToolsServicePath = Join-Path $repoRootForIggTools 'IggToolsL2\services\remote_server_service.py'
if (-not (Test-Path -LiteralPath $iggToolsServicePath)) {
    $repoRootForIggTools = Split-Path -Parent $repoRootForIggTools
    $iggToolsServicePath = Join-Path $repoRootForIggTools 'IggToolsL2\services\remote_server_service.py'
}
if (Test-Path -LiteralPath $iggToolsServicePath) {
    $iggToolsText = [System.IO.File]::ReadAllText($iggToolsServicePath, [System.Text.UTF8Encoding]::new($false))
    if ($iggToolsText -notmatch 'def _pi_notify_process_rows\(port: int, config_path: Path = None\)' -or
        $iggToolsText -notmatch 'def _stop_pi_notify_processes\(port: int, config_path: Path = None\)' -or
        $iggToolsText -notmatch 'Test-PiNotifyOwnedByThisInstance' -or
        $iggToolsText -notmatch 'Test-PiNotifyCommandLineContainsPath' -or
        $iggToolsText -notmatch 'Test-PiNotifySafeToStop' -or
        $iggToolsText -notmatch 'TrimEnd\(\[System.IO.Path\]::DirectorySeparatorChar' -or
        $iggToolsText -notmatch '\$ownedScriptIds -contains \$_\.ParentProcessId' -or
        $iggToolsText -notmatch 'candidates = \[configured, str\(system_ssh\), "ssh\.exe"\]' -or
        $iggToolsText -notmatch '"-TunnelStartupDelaySeconds", "5"' -or
        $iggToolsText -notmatch '"-StartupDelaySeconds", "5"' -or
        $iggToolsText -notmatch '_stop_pi_notify_processes\(port, config_path\)' -or
        $iggToolsText -notmatch 'running = bool\(listener_running and listener_healthy and tunnel_running and watchdog_running and remote_healthy\)' -or
        $iggToolsText -match 'payload\["ok"\] = bool\(payload\.get\("available"\)\)' -or
        $iggToolsText -notmatch 'payload\["ok"\] = bool\(payload\.get\("running"\) and payload\.get\("listenerRunning"\) and payload\.get\("listenerHealthy"\) and payload\.get\("tunnelRunning"\) and payload\.get\("watchdogRunning"\) and payload\.get\("remoteHealthy"\)\)' -or
        $iggToolsText -notmatch 'payload\["ok"\] = bool\(payload\.get\("available"\) and not payload\.get\("running"\) and payload\.get\("statusText"\) == "STOPPED"\)' -or
        $iggToolsText -notmatch 'for attempt in range\(18\)' -or
        $iggToolsText -notmatch 'time\.sleep\(1\.0\)' -or
        $iggToolsText -notmatch 'if bool\(payload\.get\("running"\) and payload\.get\("listenerRunning"\)') {
        throw 'IggTools pi-notify integration must use instance-owned process filtering, configured SSH priority, strict ok reporting, wait for delayed tunnel startup, and nonzero startup delays.'
    }
}
Write-Host 'OK IggTools pi-notify integration safeguards'
Write-Host 'OK PS5 token generation, pull branch detection, custom RemotePiDir, configured sshExecutable, Linux user autostart, and watchdog python3 safeguards'

Write-Host '[5/10] dangerous fallback grep...'
$scanFiles = Get-ChildItem -LiteralPath $repoDir -Recurse -File -Include '*.ps1','*.ts','*.md','*.json' |
    Where-Object { $_.FullName -notmatch '\\.git\\' -and $_.FullName -ne $PSCommandPath }
$bad = $scanFiles | Select-String -Pattern 'fallback-wt|new-tab' -ErrorAction SilentlyContinue
if ($bad) {
    $bad | Format-Table Path,LineNumber,Line -AutoSize
    throw 'Dangerous fallback pattern found.'
}
Write-Host 'OK no fallback-wt/new-tab'

$popupLogDir = Join-Path (Split-Path -Parent $configPath) 'logs'
if (Test-Path -LiteralPath $popupLogDir) {
    $popupArtifacts = @()
    foreach ($pattern in @('popup-payload.json', 'popup-dedupe.json', 'popup-stdout.log', 'popup-stderr.log', 'popup-payload.*.json', 'popup-dedupe.*.json', 'popup-stdout.*.log', 'popup-stderr.*.log')) {
        $popupArtifacts += @(Get-ChildItem -LiteralPath $popupLogDir -Filter $pattern -File -ErrorAction SilentlyContinue)
    }
    $leakyLogs = @($popupArtifacts | Where-Object { $_.Name -eq 'popup-stdout.log' -or $_.Name -eq 'popup-stderr.log' -or $_.Name -like 'popup-stdout.*.log' -or $_.Name -like 'popup-stderr.*.log' })
    if ($leakyLogs.Count -gt 0) {
        throw ('Popup stdout/stderr artifacts remain: {0}' -f (($leakyLogs | Select-Object -First 5 -ExpandProperty Name) -join ', '))
    }
    foreach ($payloadArtifact in @($popupArtifacts | Where-Object { $_.Name -eq 'popup-payload.json' -or $_.Name -like 'popup-payload.*.json' })) {
        $text = [System.IO.File]::ReadAllText($payloadArtifact.FullName, [System.Text.UTF8Encoding]::new($false))
        if ($text -match '"title"\s*:' -or $text -match '"body"\s*:' -or $text -match '"cwdBase"\s*:' -or $text -match '"tabTitle"\s*:' -or $text -match '"focusTarget"\s*:') {
            throw ('Sensitive popup payload artifact remains: {0}' -f $payloadArtifact.Name)
        }
    }
    $cachePath = Join-Path $popupLogDir 'popup-cache.json'
    if (Test-Path -LiteralPath $cachePath) {
        $cacheText = [System.IO.File]::ReadAllText($cachePath, [System.Text.UTF8Encoding]::new($false))
        if ($cacheText -match '"host"\s*:' -or $cacheText -match '"cwdBase"\s*:' -or $cacheText -match '"windowTitle"\s*:' -or $cacheText -match '"tabTitle"\s*:') {
            throw 'Popup cache contains raw target context.'
        }
    }
    $stalePopupArtifacts = @($popupArtifacts | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) })
    if ($stalePopupArtifacts.Count -gt 0 -or $popupArtifacts.Count -gt 8) {
        throw ('Stale or excessive popup artifacts remain: count={0} stale={1}' -f $popupArtifacts.Count, $stalePopupArtifacts.Count)
    }
    foreach ($logName in @('listener.log', 'popup.log', 'activate.log', 'broker.log')) {
        $logPath = Join-Path $popupLogDir $logName
        if (-not (Test-Path -LiteralPath $logPath)) { continue }
        $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.UTF8Encoding]::new($false))
        $badRuntimeNotificationLogPattern = ('notify ' + 'title=') + '|' + ('system-toast ' + 'title=') + '|' + ('notify-drop missing-target-metadata ' + 'title=') + '|' + ('popup-launch ' + 'title=') + '|' + ('popup-start ' + 'title=') + '|' + ('popup-' + 'action .*' + 'tit' + 'le=') + '|' + 'sourceTabTitle="' + '|' + 'cwdBase="' + '|' + 'sessionName="' + '|' + 'windowTitle="' + '|' + 'tabTitle="' + '|' + 'keywords="' + '|' + 'popup-window title="' + '|' + 'popup-tab .*name="' + '|' + 'popup-action activate host=' + '|' + 'popup-cache host="' + '|' + 'activate-target host=' + '|' + 'activate-focus-miss .*host=' + '|' + 'notify-dedup .*focusTarget=' + '|' + 'notify focusTarget='
        if ($logText -match $badRuntimeNotificationLogPattern) {
            throw ('Notification content or raw target context remains in runtime log: {0}' -f $logName)
        }
    }
}
Write-Host 'OK no stale/sensitive popup artifacts or notification-content logs'

Write-Host '[6/10] local listener health...'
$cfg = $null
if (Test-Path -LiteralPath $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $health = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$($cfg.port)/health" -TimeoutSec 3
    Write-Host ('OK {0} {1}' -f $cfg.port, $health.Content)
}
else {
    Write-Host 'SKIP no local config'
}

Write-Host '[7/10] remote extension copies...'
if ($null -ne $cfg -and -not [string]::IsNullOrWhiteSpace([string]$cfg.remoteHostAlias)) {
    $remoteAudit = @'
import os
import stat
import sys

paths = []
for name in (
    "~/.local/share/pi-notify/remote-windows-notify.ts",
    "~/.pi/agent/extensions/remote-windows-notify.ts",
):
    path = os.path.expanduser(name)
    if os.path.isfile(path):
        paths.append(path)

package_root = os.path.expanduser("~/.pi/agent/git/github.com/zk541040600/pi_remote-windows-notify")
if os.path.isdir(package_root):
    for dirpath, _dirnames, filenames in os.walk(package_root):
        if "remote-windows-notify.ts" in filenames:
            paths.append(os.path.join(dirpath, "remote-windows-notify.ts"))

paths = sorted(set(paths))
if not paths:
    print("BAD no remote extension copies found")
    sys.exit(3)

bad = []
for path in paths:
    with open(path, "r", encoding="utf-8-sig") as handle:
        text = handle.read()
    ok = "__piRemoteWindowsNotifyRegistered" in text and "cachedConfigPromise" not in text and "127.0.0.1:23118/notify" in text and "getExtensionConfigPaths" in text and "fileURLToPath(import.meta.url)" in text
    print(("OK " if ok else "BAD ") + path)
    if not ok:
        bad.append(path)

if bad:
    sys.exit(2)
print(f"checked {len(paths)} remote extension copies")

config_bad = []
checked_config = 0
for name in (
    "~/.local/share/pi-notify/remote-windows-notify.json",
    "~/.pi/agent/remote-windows-notify.json",
):
    path = os.path.expanduser(name)
    if not os.path.isfile(path):
        continue
    checked_config += 1
    mode = stat.S_IMODE(os.stat(path).st_mode)
    ok = mode == 0o600
    print(("OK " if ok else "BAD ") + f"{path} mode={mode:03o}")
    if not ok:
        config_bad.append(path)

if checked_config == 0:
    print("BAD no remote token config files found")
    sys.exit(4)
if config_bad:
    sys.exit(4)
print(f"checked {checked_config} remote token config files")
'@
    $remoteSsh = if ($cfg.PSObject.Properties['sshExecutable'] -and -not [string]::IsNullOrWhiteSpace([string]$cfg.sshExecutable)) { [string]$cfg.sshExecutable } else { 'ssh.exe' }
    $remoteAuditB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remoteAudit))
    $remoteCommand = ('tmp=/tmp/pi_notify_audit_$$.py; printf %s ''{0}'' | base64 -d > "$tmp" && python3 "$tmp"; rc=$?; rm -f "$tmp"; exit $rc' -f $remoteAuditB64)
    $remoteArgs = Join-NotifyBridgeProcessArguments @(
        '-T',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=2',
        ([string]$cfg.remoteHostAlias),
        $remoteCommand
    )
    $remoteStdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-check-remote-{0}.out' -f ([Guid]::NewGuid().ToString('N')))
    $remoteStderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-check-remote-{0}.err' -f ([Guid]::NewGuid().ToString('N')))
    $remoteProcess = Start-Process -FilePath $remoteSsh -ArgumentList $remoteArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $remoteStdoutPath -RedirectStandardError $remoteStderrPath
    if ($null -eq $remoteProcess) {
        throw ('Remote extension audit failed to start via {0}. Run pi-notify-refresh.ps1 -SyncRemote.' -f $remoteSsh)
    }
    if (-not $remoteProcess.WaitForExit(60000)) {
        try { Stop-Process -Id $remoteProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw ('Remote extension audit timed out via {0}. Run pi-notify-refresh.ps1 -SyncRemote.' -f $remoteSsh)
    }
    try { $remoteProcess.Refresh() } catch {}
    $remoteStdout = if (Test-Path -LiteralPath $remoteStdoutPath) { [string](Get-Content -LiteralPath $remoteStdoutPath -Raw -ErrorAction SilentlyContinue) } else { '' }
    $remoteStderr = if (Test-Path -LiteralPath $remoteStderrPath) { [string](Get-Content -LiteralPath $remoteStderrPath -Raw -ErrorAction SilentlyContinue) } else { '' }
    Remove-Item -LiteralPath $remoteStdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $remoteStderrPath -Force -ErrorAction SilentlyContinue
    $remoteOutput = @()
    foreach ($chunk in @($remoteStdout, $remoteStderr)) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        $remoteOutput += @($chunk -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $remoteText = $remoteOutput -join "`n"
    $remoteExitCodeText = ''
    try { $remoteExitCodeText = [string]$remoteProcess.ExitCode } catch { $remoteExitCodeText = '' }
    $remoteSuccessByOutput = ($remoteText -match 'checked \d+ remote extension copies' -and $remoteText -match 'checked \d+ remote token config files' -and $remoteText -notmatch '^BAD ')
    if ($remoteExitCodeText -eq '0' -or $remoteSuccessByOutput) {
        $remoteOutput | ForEach-Object { Write-Host $_ }
    }
    elseif ($remoteExitCodeText -eq '2' -or $remoteText -match '^BAD .*remote-windows-notify\.ts') {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw 'Stale remote extension copy found. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    elseif ($remoteExitCodeText -eq '3' -or $remoteText -match 'BAD no remote extension copies found') {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw 'No remote extension copies found. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    elseif ($remoteExitCodeText -eq '4' -or $remoteText -match 'BAD .*mode=|BAD no remote token config files found') {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw 'Remote token config permissions are unsafe. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    else {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw ('Remote extension audit failed via {0}. Run pi-notify-refresh.ps1 -SyncRemote.' -f $remoteSsh)
    }
}
else {
    Write-Host 'SKIP no remote host in local config'
}

Write-Host '[8/10] autostart listener ownership...'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$listenerVbs = Join-Path $startupDir 'PiNotifyListener.vbs'
$autostartChecked = $false
if (Test-Path -LiteralPath $listenerVbs) {
    $autostartChecked = $true
    $content = [System.IO.File]::ReadAllText($listenerVbs)
    if ($content -match 'notify-listener\.ps1' -and $content -notmatch 'pi-notify-restart-listener\.ps1') {
        throw ('Startup listener launcher uses notify-listener.ps1 directly: {0}' -f $listenerVbs)
    }
    Write-Host ('OK listener VBS: {0}' -f $listenerVbs)
}
foreach ($taskName in @('PiNotifyListener', 'PiNotifyTunnel', 'PiNotifyWatchdog')) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        throw ('Legacy scheduled task should have been removed by install-windows-autostart.ps1: {0}' -f $taskName)
    }
}
Write-Host 'OK no legacy PiNotify scheduled tasks'
$hotkeyVbs = Join-Path $startupDir 'PiNotifyHotkey.vbs'
if ($null -ne $cfg -and $cfg.PSObject.Properties['popupHotkeyEnabled'] -and [bool]$cfg.popupHotkeyEnabled) {
    if (-not (Test-Path -LiteralPath $hotkeyVbs)) {
        throw ('Startup hotkey launcher missing: {0}' -f $hotkeyVbs)
    }
    $hotkeyVbsText = [System.IO.File]::ReadAllText($hotkeyVbs)
    if ($hotkeyVbsText -notmatch 'pi-notify-hotkey\.ps1' -or $hotkeyVbsText -match '-Once') {
        throw ('Startup hotkey launcher must run resident pi-notify-hotkey.ps1 without -Once: {0}' -f $hotkeyVbs)
    }
    Write-Host ('OK hotkey VBS: {0}' -f $hotkeyVbs)
}
if (-not $autostartChecked) {
    Write-Host 'SKIP no listener autostart registered'
}

Write-Host '[9/10] runtime singleton health...'
if ($null -ne $cfg) {
    $forwardNeedle = ('127.0.0.1:{0}:127.0.0.1:{0}' -f ([int]$cfg.port))
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $instanceBinDir = Join-Path $runtimeBaseDir 'bin'
    $checkInstancePaths = @($configPath, $instanceBinDir, $runtimeBaseDir)
    $directListenerPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $checkInstancePaths) -and ($commandLine -match '(?i)-File\s+("[^"]*notify-listener\.ps1"|[^\s"]*notify-listener\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $listenerRunnerPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $checkInstancePaths) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-listener-runner\.ps1"|[^\s"]*pi-notify-listener-runner\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $listenerPidOk = $false
    $listenerPidPath = Join-Path $runtimeBaseDir 'listener.pid'
    if (Test-Path -LiteralPath $listenerPidPath) {
        $rawListenerPid = [string](Get-Content -LiteralPath $listenerPidPath -Raw -ErrorAction SilentlyContinue)
        $listenerPidValue = 0
        if ([int]::TryParse($rawListenerPid.Trim(), [ref]$listenerPidValue)) {
            $listenerPidOk = @($listenerRunnerPids | Where-Object { $_ -eq $listenerPidValue }).Count -eq 1
        }
    }
    if (-not ($cfg.PSObject.Properties['tunnelStartupDelaySeconds']) -or [int]$cfg.tunnelStartupDelaySeconds -lt 5) {
        throw 'Runtime config must persist tunnelStartupDelaySeconds >= 5; run pi-notify-refresh.ps1 -SyncRemote.'
    }
    Write-Host ('listenerDirect={0} listenerRunner={1} listenerPidOk={2}' -f $directListenerPids.Count, $listenerRunnerPids.Count, $listenerPidOk)
    if ($directListenerPids.Count -ne 0 -or $listenerRunnerPids.Count -ne 1 -or -not $listenerPidOk) {
        throw 'Listener must be owned by exactly one listener runner with matching listener.pid. Run pi-notify-refresh.ps1 -SyncRemote.'
    }

    $wrapperPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $checkInstancePaths) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-reverse-tunnel\.ps1"|[^\s"]*pi-notify-reverse-tunnel\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $watchdogPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $checkInstancePaths) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-watchdog\.ps1"|[^\s"]*pi-notify-watchdog\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $hotkeyPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $checkInstancePaths) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-hotkey\.ps1"|[^\s"]*pi-notify-hotkey\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $sshPids = @($processes | Where-Object {
        ($_.Name -eq 'ssh.exe') -and ([string]$_.CommandLine -like ('*{0}*' -f $forwardNeedle)) -and ($wrapperPids -contains $_.ParentProcessId)
    } | Select-Object -ExpandProperty ProcessId)
    $ignoredSshPids = @($processes | Where-Object {
        ($_.Name -eq 'ssh.exe') -and ([string]$_.CommandLine -like ('*{0}*' -f $forwardNeedle)) -and -not ($wrapperPids -contains $_.ParentProcessId)
    } | Select-Object -ExpandProperty ProcessId)
    if ($ignoredSshPids.Count -gt 0) {
        Write-Host ('ignoredUnownedSsh={0}' -f $ignoredSshPids.Count)
    }
    $watchdogPidOk = $false
    $watchdogPidPath = Join-Path $runtimeBaseDir 'watchdog.pid'
    if (Test-Path -LiteralPath $watchdogPidPath) {
        $rawWatchdogPid = [string](Get-Content -LiteralPath $watchdogPidPath -Raw -ErrorAction SilentlyContinue)
        $watchdogPidValue = 0
        if ([int]::TryParse($rawWatchdogPid.Trim(), [ref]$watchdogPidValue)) {
            $watchdogPidOk = @($watchdogPids | Where-Object { $_ -eq $watchdogPidValue }).Count -eq 1
        }
    }
    Write-Host ('wrappers={0} ssh={1} watchdog={2} watchdogPidOk={3} hotkey={4}' -f $wrapperPids.Count, $sshPids.Count, $watchdogPids.Count, $watchdogPidOk, $hotkeyPids.Count)
    if ($wrapperPids.Count -ne 1 -or $sshPids.Count -ne 1 -or $watchdogPids.Count -ne 1 -or -not $watchdogPidOk) {
        throw 'Reverse tunnel must have exactly one wrapper, one ssh process, one watchdog, and matching watchdog.pid. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    if ($cfg.PSObject.Properties['popupHotkeyEnabled'] -and [bool]$cfg.popupHotkeyEnabled -and $hotkeyPids.Count -ne 1) {
        throw 'Resident hotkey must have exactly one running worker when popupHotkeyEnabled=true. Run pi-notify-refresh.ps1 -SyncRemote.'
    }

    $tunnelLog = Join-Path $runtimeBaseDir 'logs\tunnel.log'
    if (Test-Path -LiteralPath $tunnelLog) {
        $recentTunnelFailures = @(Get-Content -LiteralPath $tunnelLog -Tail 20 | Where-Object { $_ -match 'tunnel-exit code=255 retry=' })
        if ($recentTunnelFailures.Count -gt 0) {
            $recentTunnelFailures | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
            throw 'Recent reverse tunnel retry failures found.'
        }
    }
    $watchdogLog = Join-Path $runtimeBaseDir 'logs\watchdog.log'
    if (Test-Path -LiteralPath $watchdogLog) {
        $watchdogLines = @(Get-Content -LiteralPath $watchdogLog -Tail 40)
        $recentWatchdogFailures = @($watchdogLines | Where-Object { $_ -match 'watchdog-error|duplicate-tunnel|stale-broker' })
        if ($recentWatchdogFailures.Count -gt 0) {
            $recentWatchdogFailures | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
            throw 'Recent watchdog error, duplicate tunnel, or stale broker repair found.'
        }
        # stale-listener lines are expected when health is false; only flag false-positive
        # restarts where listenerOk=True and duplicate=False (shape-only false restarts).
        $recentStaleListenerRestarts = @($watchdogLines | Where-Object { $_ -match 'stale-listener' -and $_ -match 'listenerOk=True' -and $_ -match 'duplicate=False' })
        if ($recentStaleListenerRestarts.Count -gt 0) {
            $recentStaleListenerRestarts | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
            throw 'Recent false stale-listener restart while listenerOk=True and duplicate=False found.'
        }
    }
    Write-Host 'OK tunnel singleton healthy'
}
else {
    Write-Host 'SKIP no local config'
}

Write-Host '[10/10] broker health...'
if ($null -ne $cfg) {
    $brokerEnabled = $false
    if ($cfg.PSObject.Properties['brokerEnabled']) {
        try { $brokerEnabled = [bool]$cfg.brokerEnabled } catch { $brokerEnabled = $false }
    }
    if ($brokerEnabled) {
        $brokerPort = 23119
        if ($cfg.PSObject.Properties['brokerPort']) { try { $brokerPort = [int]$cfg.brokerPort } catch {} }
        try {
            $brokerHealth = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$brokerPort/health" -TimeoutSec 3
            Write-Host ('OK broker {0} {1}' -f $brokerPort, $brokerHealth.Content)
        }
        catch {
            Write-Host ('WARN broker health unavailable on port {0}; listener will use fallback' -f $brokerPort)
        }
    }
    else {
        Write-Host 'SKIP broker disabled in config'
    }
}
else {
    Write-Host 'SKIP no local config'
}

Write-Host 'Done.'
