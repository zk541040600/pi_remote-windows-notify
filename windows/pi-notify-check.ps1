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

Write-Host '[1/9] PowerShell syntax...'
foreach ($path in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | Sort-Object Name) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $errors | Format-List
        throw ('Syntax check failed: {0}' -f $path.FullName)
    }
    Write-Host ('OK {0}' -f $path.Name)
}

Write-Host '[2/9] PS1 ASCII source...'
foreach ($path in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($path.FullName)) {
        $lineNumber += 1
        foreach ($ch in $line.ToCharArray()) {
            if ([int][char]$ch -gt 127) {
                throw ('Non-ASCII PowerShell source: {0}:{1}' -f $path.FullName, $lineNumber)
            }
        }
    }
}
Write-Host 'OK no non-ascii ps1 source'

Write-Host '[3/9] PowerShell automatic variable hazards...'
$forbiddenLoopVar = 'foreach\s*\(\s*\$' + 'pid\b'
foreach ($path in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($path.FullName)) {
        $lineNumber += 1
        if ($line -match $forbiddenLoopVar) {
            throw ('PowerShell automatic variable loop hazard: {0}:{1}' -f $path.FullName, $lineNumber)
        }
    }
}
Write-Host 'OK no foreach $pid hazard'

Write-Host '[4/9] extension template drift...'
$linuxExtensionPath = Join-Path $repoDir 'linux\extensions\remote-windows-notify.ts'
$windowsExtensionPath = Join-Path $repoDir 'windows\remote-windows-notify.ts'
$flatExtensionPath = Join-Path $PSScriptRoot 'remote-windows-notify.ts'
if ((Test-Path -LiteralPath $linuxExtensionPath) -and (Test-Path -LiteralPath $windowsExtensionPath)) {
    $linuxExtension = [System.IO.File]::ReadAllText($linuxExtensionPath, [System.Text.UTF8Encoding]::new($false))
    $windowsExtension = [System.IO.File]::ReadAllText($windowsExtensionPath, [System.Text.UTF8Encoding]::new($false))
    if ($linuxExtension -ne $windowsExtension) {
        throw 'Linux and Windows extension templates differ. Copy the canonical extension before shipping.'
    }
    if ($windowsExtension -notmatch 'getExtensionConfigPaths' -or $windowsExtension -notmatch 'fileURLToPath\(import\.meta\.url\)') {
        throw 'Extension template must discover remote-windows-notify.json relative to its installed path for custom -RemotePiDir.'
    }
    Write-Host 'OK extension templates match'
}
elseif (Test-Path -LiteralPath $flatExtensionPath) {
    $flatExtension = [System.IO.File]::ReadAllText($flatExtensionPath, [System.Text.UTF8Encoding]::new($false))
    if ($flatExtension -notmatch '__piRemoteWindowsNotifyRegistered' -or $flatExtension -match 'cachedConfigPromise' -or $flatExtension -notmatch '127\.0\.0\.1:23118/notify' -or $flatExtension -notmatch 'getExtensionConfigPaths' -or $flatExtension -notmatch 'fileURLToPath\(import\.meta\.url\)') {
        throw 'Flat extension template is stale.'
    }
    Write-Host 'OK flat extension template is current'
}
else {
    throw 'No remote-windows-notify.ts template found.'
}

$commonText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($commonText -match 'RandomNumberGenerator\]::Fill' -or $commonText -notmatch 'RandomNumberGenerator\]::Create\(\)' -or $commonText -notmatch '\.GetBytes\(\$buffer\)') {
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
    $probeConfig = Ensure-NotifyBridgeConfig -ConfigPath $customProbeConfig -Port 23119 -SshExecutable 'ssh.exe' -RemoteHostAlias 'probe' -TunnelStartupDelaySeconds 0
    if ((Get-NotifyBridgeBaseDir) -ne $customProbeBase -or (Get-NotifyBridgeBinDir) -ne (Join-Path $customProbeBase 'bin') -or (Get-NotifyBridgeLogDir) -ne (Join-Path $customProbeBase 'logs') -or [int]$probeConfig.TunnelStartupDelaySeconds -lt 5) {
        throw 'ConfigPath probe failed.'
    }
    $reloadProbeConfig = Ensure-NotifyBridgeConfig -ConfigPath $customProbeConfig
    $reloadRaw = Get-Content -LiteralPath $customProbeConfig -Raw | ConvertFrom-Json
    if ([string]$reloadProbeConfig.SshExecutable -ne 'ssh.exe' -or [string]$reloadRaw.sshExecutable -ne 'ssh.exe') {
        throw 'Existing bare sshExecutable must survive reload from ConfigPath.'
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
foreach ($path in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $scriptText = [System.IO.File]::ReadAllText($path.FullName, [System.Text.UTF8Encoding]::new($false))
    if ($scriptText -match $badStartProcessArrayPattern) {
        throw ('Unsafe child process argument array in {0}; use quoted single-string arguments.' -f $path.Name)
    }
}
$listenerTextForLaunch = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'notify-listener.ps1'), [System.Text.UTF8Encoding]::new($false))
$popupTextForArtifacts = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-popup.ps1'), [System.Text.UTF8Encoding]::new($false))
$activateTextForArtifacts = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-activate.ps1'), [System.Text.UTF8Encoding]::new($false))
$hotkeyTextForArtifacts = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-hotkey.ps1'), [System.Text.UTF8Encoding]::new($false))
$refreshTextForArtifacts = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-refresh.ps1'), [System.Text.UTF8Encoding]::new($false))
$commonTextForToastSetup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'), [System.Text.UTF8Encoding]::new($false))
$installerTextForToastSetup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-remote-windows-notify.ps1'), [System.Text.UTF8Encoding]::new($false))
$autostartTextForToastSetup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-windows-autostart.ps1'), [System.Text.UTF8Encoding]::new($false))
$setModeTextForToastSetup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'set-notify-mode.ps1'), [System.Text.UTF8Encoding]::new($false))
$shortcutHelperTextForToastSetup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'register-toast-shortcut.py'), [System.Text.UTF8Encoding]::new($false))
if ($listenerTextForLaunch -notmatch 'Join-NotifyBridgeProcessArguments' -or $listenerTextForLaunch -match 'RedirectStandardOutput\s+\$popupStdoutLogPath' -or $listenerTextForLaunch -match 'popup-stdout\.\{0\}' -or $listenerTextForLaunch -match 'targetKey\s*=\s*\$targetKey' -or $listenerTextForLaunch -match 'popup-[^\r\n]+targetKey=' -or $listenerTextForLaunch -match 'title\s*=\s*\$Title' -or $listenerTextForLaunch -match 'body\s*=\s*\$Body' -or $listenerTextForLaunch -match 'focusTarget\s*=\s*\$focusTarget' -or $listenerTextForLaunch -match 'cwdBase\s*=\s*\$cwdBase' -or $listenerTextForLaunch -match 'tabTitle\s*=\s*\$tabTitle' -or $listenerTextForLaunch -match '\''-Title\'', \$Title' -or $listenerTextForLaunch -match '\''-Body\'', \$Body' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_TITLE' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_BODY' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_CWD_BASE') {
    throw 'Popup launch must quote paths, avoid per-popup stdout/stderr files, and avoid storing/logging raw target keys or title/body/context in payload files or command lines.'
}
if ($popupTextForArtifacts -notmatch 'PI_NOTIFY_TITLE' -or $popupTextForArtifacts -notmatch 'PI_NOTIFY_BODY' -or $popupTextForArtifacts -notmatch 'PI_NOTIFY_CWD_BASE' -or $popupTextForArtifacts -match "PSObject.Properties\['title'\]" -or $popupTextForArtifacts -match "PSObject.Properties\['body'\]" -or $popupTextForArtifacts -match "PSObject.Properties\['cwdBase'\]" -or $popupTextForArtifacts -match "PSObject.Properties\['tabTitle'\]") {
    throw 'Popup process must read sensitive notification text/context from child environment, not disk payload.'
}
if ($popupTextForArtifacts -match 'sanitizedPayload' -or $popupTextForArtifacts -match 'WriteAllText\(\$PayloadPath' -or $popupTextForArtifacts -match 'Remove-Item -LiteralPath \$script:NotifyPopupDedupePath') {
    throw 'Popup process must avoid creating live payload/dedupe artifacts; listener supplies non-sensitive metadata via command line.'
}
if ($popupTextForArtifacts -notmatch 'Get-NotifyPopupContextFingerprint' -or $popupTextForArtifacts -match 'popup-cache host="' -or $popupTextForArtifacts -match 'popup-cache .*cwdBase=' -or $popupTextForArtifacts -match 'popup-window title="' -or $popupTextForArtifacts -match 'popup-tab .*name="' -or $popupTextForArtifacts -match 'popup-focus-best windowTitle=' -or $popupTextForArtifacts -match 'popup-initial-captured windowTitle=' -or $popupTextForArtifacts -match 'popup-keywords "\{0\}"' -or $popupTextForArtifacts -match 'popup-action activate host=') {
    throw 'Popup cache/logs must persist only fingerprints/counts for cwd/tab/window/keyword context.'
}
if ($popupTextForArtifacts -match 'host\s*=\s*\$TargetHostValue' -or $popupTextForArtifacts -match 'cwdBase\s*=\s*\$CwdBaseValue' -or $popupTextForArtifacts -match 'windowTitle\s*=\s*\$WindowTitle' -or $popupTextForArtifacts -match 'tabTitle\s*=\s*\$TabTitle') {
    throw 'Popup cache must not persist raw host/cwd/window/tab context.'
}
if ($popupTextForArtifacts -match 'WriteAllText\(\$PayloadPath' -or $popupTextForArtifacts -match 'popup-dedupe\.\{0\}\.json' -or $popupTextForArtifacts -match 'popup-payload-read-error') {
    throw 'Live popup processes must not leave payload/dedupe JSON artifacts; use listener-owned memory and non-sensitive command-line metadata.'
}
if ($popupTextForArtifacts -notmatch 'popup-live\.\{0\}\.json' -or $popupTextForArtifacts -notmatch 'protectedHost' -or $popupTextForArtifacts -notmatch 'protectedCwd' -or $popupTextForArtifacts -notmatch 'protectedTab' -or $hotkeyTextForArtifacts -notmatch 'Unprotect-NotifyHotkeyValue' -or $hotkeyTextForArtifacts -match 'Write-NotifyHotkeyLog[^\r\n]*TargetHost' -or $hotkeyTextForArtifacts -match 'Write-NotifyHotkeyLog[^\r\n]*CwdBase' -or $hotkeyTextForArtifacts -match 'Write-NotifyHotkeyLog[^\r\n]*TabTitle') {
    throw 'Popup hotkey live state must store DPAPI-protected target context and hotkey logs must not persist raw target context.'
}
$badListenerNotificationLogPattern = ('notify ' + 'title=') + '|' + ('system-toast ' + 'title=') + '|' + ('notify-drop missing-target-metadata ' + 'title=') + '|' + ('popup-launch ' + 'title=') + '|' + ('popup-pid .*target' + 'Key') + '|' + ('popup-launch ' + 'focusTarget=') + '|' + ('notify-dedup .*focusTarget=') + '|' + ('notify focusTarget=')
$badPopupNotificationLogPattern = ('popup-start ' + 'title=') + '|' + ('popup-' + 'action .*' + 'tit' + 'le=') + '|' + ('popup-drop missing-target-metadata ' + 'title=') + '|' + ('popup-dedup drop-imprecise ' + 'title=') + '|' + 'sourceTabTitle="' + '|' + 'cwdBase="' + '|' + 'windowTitle="' + '|' + 'tabTitle="' + '|' + 'keywords="' + '|' + 'name="'
$badActivateNotificationLogPattern = 'activate-target host=' + '|' + 'activate-focus-miss .*host='
if ($listenerTextForLaunch -match $badListenerNotificationLogPattern -or $popupTextForArtifacts -match $badPopupNotificationLogPattern -or $activateTextForArtifacts -match $badActivateNotificationLogPattern) {
    throw 'Listener/popup/activate logs must not persist notification title/body text or raw target context.'
}
if ($activateTextForArtifacts -notmatch 'Get-NotifyActivateFingerprint \$targetHost' -or $activateTextForArtifacts -match 'activate-target host="' -or $activateTextForArtifacts -match 'activate-focus-miss .*host="') {
    throw 'Activate script must log target host only as a fingerprint.'
}
if ($listenerTextForLaunch -notmatch '\$maxBodyBytes\s*=\s*65536' -or $listenerTextForLaunch -notmatch '\$contentLength -gt \$maxBodyBytes' -or $listenerTextForLaunch -notmatch 'HTTP request body too large') {
    throw 'Listener Read-HttpRequest must cap request bodies to avoid memory/connection abuse.'
}
if ($listenerTextForLaunch -match "'host=' \+ \[Uri\]::EscapeDataString" -or $listenerTextForLaunch -match "'cwdBase=' \+ \[Uri\]::EscapeDataString" -or $listenerTextForLaunch -match "'tabTitle=' \+ \[Uri\]::EscapeDataString" -or $listenerTextForLaunch -match '''-ConfigPath'', \$ConfigPath,\s*\r?\n\s*\$LaunchUri' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_FOCUS_TARGET' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_CWD_BASE' -or $listenerTextForLaunch -notmatch 'PI_NOTIFY_TAB_TITLE' -or $listenerTextForLaunch -notmatch 'Save-NotifyToastActivationState' -or $listenerTextForLaunch -notmatch "SetAttribute\('activationType', 'protocol'\)" -or $listenerTextForLaunch -notmatch 'ProtectedData\]::Protect' -or $listenerTextForLaunch -notmatch 'activation-\{0\}\.json') {
    throw 'System-toast activation must not persist raw host/cwd/tab in launch URI or activation command line; use protocol activationType, protected activation cache, and child environment.'
}
if ($listenerTextForLaunch -notmatch 'Get-NotifyCommandLineArgument' -or $listenerTextForLaunch -notmatch "Name 'ConfigPath'" -or $listenerTextForLaunch -notmatch "Name 'TargetFingerprint'" -or $listenerTextForLaunch -notmatch "Name 'StackIndex'" -or $listenerTextForLaunch -notmatch 'GetFullPath\(\$popupConfigPath\)\.Equals' -or $listenerTextForLaunch -match 'popup-payload\.\{0\}\.json') {
    throw 'Popup process scans must be limited by matching ConfigPath and non-sensitive TargetFingerprint/StackIndex command-line metadata, without live payload files.'
}
if ($listenerTextForLaunch -notmatch 'NotifyActivationCleanupTimers' -or $listenerTextForLaunch -notmatch 'TimerCallback' -or $listenerTextForLaunch -notmatch '\[TimeSpan\]::FromMinutes\(10\)' -or $listenerTextForLaunch -match 'Register-ObjectEvent' -or $listenerTextForLaunch -match 'system-toast-activation-events-unavailable') {
    throw 'System-toast activation must use protocol activation plus bounded cache timers; do not attempt unsupported PS5 WinRT event subscriptions.'
}
if ($activateTextForArtifacts -notmatch 'Resolve-NotifyActivationState' -or $activateTextForArtifacts -notmatch 'ProtectedData\]::Unprotect' -or $activateTextForArtifacts -notmatch 'Get-NotifyQueryValue -ParsedUri \$parsedUri -Name ''id''' -or $activateTextForArtifacts -notmatch '\$keywords = @\(\$tabTitle, \$cwdBase, \$targetHost\) \| Where-Object') {
    throw 'Activate script must resolve nonce-only system-toast activation ids and filter empty focus keywords before UI Automation binding.'
}
if ($commonTextForToastSetup -notmatch 'function Register-NotifyBridgeSystemToastSupport' -or $commonTextForToastSetup -notmatch 'Register-NotifyBridgeProtocolHandler' -or $commonTextForToastSetup -notmatch 'Register-NotifyBridgeToastShortcut' -or $commonTextForToastSetup -notmatch 'SHGetPropertyStoreFromParsingName' -or $commonTextForToastSetup -notmatch 'New-Object -ComObject WScript.Shell' -or $commonTextForToastSetup -notmatch 'Pi Remote\.lnk' -or $commonTextForToastSetup -match 'Get-Command python') {
    throw 'Common must expose one shared setup path for system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
if ($installerTextForToastSetup -notmatch 'Register-NotifyBridgeSystemToastSupport -ConfigPathValue \$config\.ConfigPath' -or $installerTextForToastSetup -notmatch 'Toast link' -or $installerTextForToastSetup -notmatch 'Click URI') {
    throw 'Fresh/manual remote installer must register system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
if ($autostartTextForToastSetup -notmatch 'Register-NotifyBridgeSystemToastSupport -ConfigPathValue \$config\.ConfigPath' -or $autostartTextForToastSetup -notmatch 'Toast link' -or $autostartTextForToastSetup -notmatch 'Click URI') {
    throw 'Windows autostart installer must register system-toast protocol handler and Pi Remote toast shortcut/AUMID.'
}
$setModeRegisterIndex = $setModeTextForToastSetup.IndexOf('Register-NotifyBridgeSystemToastSupport -ConfigPathValue $config.ConfigPath')
$setModeRestartIndex = $setModeTextForToastSetup.IndexOf('if ($RestartListener)')
if ($setModeRegisterIndex -lt 0 -or $setModeRestartIndex -lt 0 -or $setModeRegisterIndex -gt $setModeRestartIndex -or $setModeTextForToastSetup -match 'register-toast-shortcut\.py.*try') {
    throw 'set-notify-mode must register system-toast protocol/shortcut support even when -RestartListener:$false is used.'
}
if ($refreshTextForArtifacts -notmatch 'Clear-NotifyPopupRuntimeArtifacts' -or $refreshTextForArtifacts -notmatch 'activation-\*\.json' -or $refreshTextForArtifacts -notmatch 'popup-live\.\*\.json' -or $refreshTextForArtifacts -notmatch 'popup-payload\.json' -or $refreshTextForArtifacts -notmatch 'popup-dedupe\.json' -or $refreshTextForArtifacts -notmatch 'popup-stdout\.log' -or $refreshTextForArtifacts -notmatch 'popup-stderr\.log' -or $refreshTextForArtifacts -notmatch 'popup-payload\.\*\.json' -or $refreshTextForArtifacts -notmatch 'popup-dedupe\.\*\.json' -or $refreshTextForArtifacts -notmatch 'popup-stdout\.\*\.log' -or $refreshTextForArtifacts -notmatch 'popup-stderr\.\*\.log' -or $refreshTextForArtifacts -notmatch 'listener\.log' -or $refreshTextForArtifacts -notmatch 'popup\.log' -or $refreshTextForArtifacts -notmatch 'activate\.log') {
    throw 'Refresh must clear stale activation cache, popup payload/dedupe/stdout/stderr artifacts, including legacy exact names, and old notification-content logs.'
}
$restartText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-restart-listener.ps1'), [System.Text.UTF8Encoding]::new($false))
$runnerText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-listener-runner.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($restartText -notmatch 'Sync-LocalRuntimeFiles' -or $restartText -notmatch 'notify-listener\.ps1' -or $restartText -notmatch 'pi-notify-listener-runner\.ps1' -or $restartText -notmatch 'Test-NotifyProcessOwnedByThisInstance' -or $restartText -notmatch 'Test-NotifyCommandLineContainsPath' -or $restartText -notmatch 'skip unowned listener process' -or $restartText -notmatch 'Split-Path -Parent \$ConfigPath' -or $restartText -match '\$baseDir = "\$env:USERPROFILE\\.pi-notify"') {
    throw 'Restart listener must bootstrap required runtime files and derive instance base from ConfigPath.'
}
if ($refreshTextForArtifacts -notmatch '\[string\]\$ConfigPath' -or $refreshTextForArtifacts -notmatch 'Test-NotifyProcessOwnedByThisInstance' -or $refreshTextForArtifacts -notmatch 'Test-NotifyCommandLineContainsPath' -or $refreshTextForArtifacts -notmatch 'skip unowned process' -or $refreshTextForArtifacts -notmatch 'AllowParentScopedSsh' -or $refreshTextForArtifacts -notmatch 'AllowedParentProcessIds' -or $refreshTextForArtifacts -notmatch 'ParentProcessId' -or $refreshTextForArtifacts -match "Name -ne 'ssh\.exe'" -or $refreshTextForArtifacts -notmatch '\$wrapperIds -contains \$_.ParentProcessId' -or $refreshTextForArtifacts -notmatch 'keep existing reverse tunnel; restart watchdog' -or $refreshTextForArtifacts -notmatch "'-StartupDelaySeconds', '5'" -or $refreshTextForArtifacts -notmatch "'-TunnelStartupDelaySeconds', '5'" -or $refreshTextForArtifacts -match '\$baseDir = "\$env:USERPROFILE\\.pi-notify"') {
    throw 'Refresh must derive instance base from ConfigPath, scope ssh by wrapper parent, skip unowned pid-file PIDs, and use nonzero startup delays.'
}
if ($runnerText -match 'Split-Path -Parent \$PSScriptRoot' -or $runnerText -notmatch 'Get-NotifyBridgeBaseDir' -or $runnerText -notmatch 'Set-NotifyBridgeActiveConfigPath') {
    throw 'Listener runner must write listener.pid under ConfigPath-derived Get-NotifyBridgeBaseDir, not relative to script path.'
}
$watchdogText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-watchdog.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($watchdogText -match "python - <<'PY'" -or $watchdogText -notmatch "python3 - <<'PY'" -or $watchdogText -notmatch 'ConnectTimeout=10' -or $watchdogText -notmatch 'PiNotifyWatchdog_' -or $watchdogText -notmatch 'watchdog\.pid' -or $watchdogText -notmatch 'Merge-NotifyProcessIds' -or $watchdogText -notmatch 'Test-NotifyProcessOwnedByThisInstance' -or $watchdogText -notmatch 'Test-NotifyCommandLineContainsPath' -or $watchdogText -notmatch 'Test-NotifyProcessSafeToStop' -or $watchdogText -notmatch 'skip-unowned-taskkill' -or $watchdogText -notmatch 'NotifyWatchdogListenerMisses' -or $watchdogText -notmatch 'missingOwnedTunnel' -or $watchdogText -notmatch 'stale-owned-tunnel' -or $watchdogText -notmatch '\@\(\$tunnelPids\)\.Count -ne 1 -or \@\(\$sshPids\)\.Count -ne 1' -or $watchdogText -notmatch '\@\(\$tunnelPids\) -contains \$_\.ParentProcessId' -or $watchdogText -match '\$directListenerPids\s*\+\s*\$listenerRunnerPids' -or $watchdogText -match '\$tunnelPids\s*\+\s*\$sshPids') {
    throw 'Watchdog must use python3, ConnectTimeout, singleton mutex/pid guard, safe process-id merging, instance filtering, grace misses, parent-scoped ssh matching, and repair missing owned tunnel processes even if remote health passes.'
}
$tunnelText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-reverse-tunnel.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($tunnelText -notmatch 'ConnectTimeout=10') {
    throw 'Reverse tunnel must use ConnectTimeout to avoid hanging on bad SSH paths.'
}
$refreshText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pi-notify-refresh.ps1'), [System.Text.UTF8Encoding]::new($false))
$remoteInstallText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-remote-windows-notify.ps1'), [System.Text.UTF8Encoding]::new($false))
$badTempConfigPathPattern = '\$temp' + 'ConfigPath'
$badTempConfigNamePattern = 'remote-windows-notify\.' + '\{0\}' + '\.json'
if ($remoteInstallText -notmatch 'Copy-TextToRemotePath' -or $remoteInstallText -match $badTempConfigPathPattern -or $remoteInstallText -match $badTempConfigNamePattern) {
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
$linuxInstallText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-linux-autostart.ps1'), [System.Text.UTF8Encoding]::new($false))
$badRemoteUmask = 'umask 0' + '22'
$badLinuxTempConfigPattern = '\$temp' + 'Config'
if ($remoteInstallText -match $badRemoteUmask -or $linuxInstallText -match $badRemoteUmask -or $remoteInstallText -notmatch 'umask 077' -or $linuxInstallText -notmatch 'umask 077' -or $remoteInstallText -notmatch "-Mode '0600'" -or $remoteInstallText -notmatch 'remoteManagedConfigPath' -or $remoteInstallText -notmatch 'stat -c' -or $linuxInstallText -notmatch 'Copy-TextToRemotePath' -or $linuxInstallText -match $badLinuxTempConfigPattern -or $linuxInstallText -notmatch 'install -m 0600 "\$managed_dir/remote-windows-notify\.json"' -or $linuxInstallText -notmatch "-Mode '0600'") {
    throw 'Remote token config files must be uploaded/installed with umask 077 and mode 0600.'
}
$autostartAllText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-autostart-all.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($refreshText -match 'origin master' -or $refreshText -notmatch 'rev-parse --abbrev-ref --symbolic-full-name' -or $refreshText -notmatch 'branch --show-current') {
    throw 'Refresh -Pull must detect current branch/upstream instead of hard-coding origin master.'
}
if ($refreshText -notmatch '\$runtimeFiles' -or $refreshText -notmatch 'GetFullPath\(\$source\)' -or $refreshText -notmatch 'GetFullPath\(\$destination\)') {
    throw 'Refresh runtime sync must use a runtime file list with same-path skip so it works from the runtime bin.'
}
foreach ($requiredRuntimeName in @('remote-windows-notify.ts', 'popup-wallpaper.png', 'install-remote-windows-notify.ps1', 'install-linux-autostart.ps1', 'install-windows-autostart.ps1', 'install-autostart-all.ps1', 'pi-notify-check.ps1', 'pi-notify-hotkey.ps1')) {
    if ($refreshText -notmatch [regex]::Escape($requiredRuntimeName) -or $autostartAllText -match 'unused-never-match') {
        throw ('Refresh runtime sync must copy required file: {0}' -f $requiredRuntimeName)
    }
    $windowsInstallText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-windows-autostart.ps1'), [System.Text.UTF8Encoding]::new($false))
    if ($windowsInstallText -notmatch [regex]::Escape($requiredRuntimeName)) {
        throw ('Windows autostart installer must copy required runtime file: {0}' -f $requiredRuntimeName)
    }
}
$runtimeBin = Join-Path $runtimeBaseDir 'bin'
if (Test-Path -LiteralPath $runtimeBin) {
    foreach ($requiredRuntimeName in @('remote-windows-notify.ts', 'popup-wallpaper.png', 'install-remote-windows-notify.ps1', 'install-linux-autostart.ps1', 'install-windows-autostart.ps1', 'install-autostart-all.ps1', 'pi-notify-check.ps1', 'pi-notify-hotkey.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtimeBin $requiredRuntimeName))) {
            throw ('Runtime bin is missing required file: {0}' -f $requiredRuntimeName)
        }
    }
}
if ($remoteInstallText -notmatch 'Resolve-RemotePiDir' -or $remoteInstallText -notmatch 'ConvertTo-RemoteShellLiteral' -or $remoteInstallText -notmatch 'Copy-FileToRemotePath') {
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
if ($remoteInstallText -notmatch 'Resolve-WorkingNotifySshExecutable' -or $linuxInstallText -notmatch 'Resolve-WorkingNotifySshExecutable' -or $remoteInstallText -notmatch 'Ensure-NotifyBridgeConfig -ConfigPath \$config\.ConfigPath -SshExecutable \$sshExe' -or $linuxInstallText -notmatch 'Ensure-NotifyBridgeConfig -ConfigPath \$config\.ConfigPath -SshExecutable \$sshExe' -or $remoteInstallText -notmatch 'Test-NotifyBridgeExecutableAvailable -Value \$SshPath' -or $linuxInstallText -notmatch 'Test-NotifyBridgeExecutableAvailable -Value \$SshPath' -or $remoteInstallText -match '\$SshPath -ne ''ssh\.exe''' -or $linuxInstallText -match '\$SshPath -ne ''ssh\.exe''') {
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

Write-Host '[5/9] dangerous fallback grep...'
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
    foreach ($logName in @('listener.log', 'popup.log', 'activate.log')) {
        $logPath = Join-Path $popupLogDir $logName
        if (-not (Test-Path -LiteralPath $logPath)) { continue }
        $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.UTF8Encoding]::new($false))
        $badRuntimeNotificationLogPattern = ('notify ' + 'title=') + '|' + ('system-toast ' + 'title=') + '|' + ('notify-drop missing-target-metadata ' + 'title=') + '|' + ('popup-launch ' + 'title=') + '|' + ('popup-start ' + 'title=') + '|' + ('popup-' + 'action .*' + 'tit' + 'le=') + '|' + 'sourceTabTitle="' + '|' + 'cwdBase="' + '|' + 'windowTitle="' + '|' + 'tabTitle="' + '|' + 'keywords="' + '|' + 'popup-window title="' + '|' + 'popup-tab .*name="' + '|' + 'popup-action activate host=' + '|' + 'popup-cache host="' + '|' + 'activate-target host=' + '|' + 'activate-focus-miss .*host=' + '|' + 'notify-dedup .*focusTarget=' + '|' + 'notify focusTarget='
        if ($logText -match $badRuntimeNotificationLogPattern) {
            throw ('Notification content or raw target context remains in runtime log: {0}' -f $logName)
        }
    }
}
Write-Host 'OK no stale/sensitive popup artifacts or notification-content logs'

Write-Host '[6/9] local listener health...'
$cfg = $null
if (Test-Path -LiteralPath $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $health = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$($cfg.port)/health" -TimeoutSec 3
    Write-Host ('OK {0} {1}' -f $cfg.port, $health.Content)
}
else {
    Write-Host 'SKIP no local config'
}

Write-Host '[7/9] remote extension copies...'
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
    $remoteOutput = $remoteAudit | & $remoteSsh -T -o BatchMode=yes -o ConnectTimeout=10 ([string]$cfg.remoteHostAlias) 'python3 -' 2>&1
    if ($LASTEXITCODE -eq 0) {
        $remoteOutput | ForEach-Object { Write-Host $_ }
    }
    elseif ($LASTEXITCODE -eq 2) {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw 'Stale remote extension copy found. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    elseif ($LASTEXITCODE -eq 3) {
        $remoteOutput | ForEach-Object { Write-Host $_ }
        throw 'No remote extension copies found. Run pi-notify-refresh.ps1 -SyncRemote.'
    }
    elseif ($LASTEXITCODE -eq 4) {
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

Write-Host '[8/9] autostart listener ownership...'
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
if (-not $autostartChecked) {
    Write-Host 'SKIP no listener autostart registered'
}

Write-Host '[9/9] runtime singleton health...'
if ($null -ne $cfg) {
    $forwardNeedle = ('127.0.0.1:{0}:127.0.0.1:{0}' -f ([int]$cfg.port))
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $instanceBinDir = Join-Path $runtimeBaseDir 'bin'
    function Test-CheckCommandLineContainsPath {
        param([string]$CommandLine, [string]$Path)
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
    function Test-CheckProcessOwnedByInstance {
        param([string]$CommandLine)
        if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
        foreach ($needle in @($configPath, $instanceBinDir, $runtimeBaseDir)) {
            if (Test-CheckCommandLineContainsPath -CommandLine $CommandLine -Path $needle) { return $true }
        }
        return $false
    }
    $directListenerPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-CheckProcessOwnedByInstance -CommandLine $commandLine) -and ($commandLine -match '(?i)-File\s+("[^"]*notify-listener\.ps1"|[^\s"]*notify-listener\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $listenerRunnerPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-CheckProcessOwnedByInstance -CommandLine $commandLine) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-listener-runner\.ps1"|[^\s"]*pi-notify-listener-runner\.ps1)')
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
        ($_.ProcessId -ne $PID) -and (Test-CheckProcessOwnedByInstance -CommandLine $commandLine) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-reverse-tunnel\.ps1"|[^\s"]*pi-notify-reverse-tunnel\.ps1)')
    } | Select-Object -ExpandProperty ProcessId)
    $watchdogPids = @($processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        ($_.ProcessId -ne $PID) -and (Test-CheckProcessOwnedByInstance -CommandLine $commandLine) -and ($commandLine -match '(?i)-File\s+("[^"]*pi-notify-watchdog\.ps1"|[^\s"]*pi-notify-watchdog\.ps1)')
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
    Write-Host ('wrappers={0} ssh={1} watchdog={2} watchdogPidOk={3}' -f $wrapperPids.Count, $sshPids.Count, $watchdogPids.Count, $watchdogPidOk)
    if ($wrapperPids.Count -ne 1 -or $sshPids.Count -ne 1 -or $watchdogPids.Count -ne 1 -or -not $watchdogPidOk) {
        throw 'Reverse tunnel must have exactly one wrapper, one ssh process, one watchdog, and matching watchdog.pid. Run pi-notify-refresh.ps1 -SyncRemote.'
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
        $recentWatchdogFailures = @($watchdogLines | Where-Object { $_ -match 'watchdog-error|duplicate-tunnel|stale-listener' })
        if ($recentWatchdogFailures.Count -gt 0) {
            $recentWatchdogFailures | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
            throw 'Recent watchdog failure or duplicate tunnel repair found.'
        }
    }
    Write-Host 'OK tunnel singleton healthy'
}
else {
    Write-Host 'SKIP no local config'
}

Write-Host 'Done.'
