[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Security

if (-not ([System.Management.Automation.PSTypeName]'PiNotifyHotkeyNative').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PiNotifyHotkeyNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public UInt32 message;
        public IntPtr wParam;
        public IntPtr lParam;
        public UInt32 time;
        public POINT pt;
    }

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, UInt32 fsModifiers, UInt32 vk);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, UInt32 wMsgFilterMin, UInt32 wMsgFilterMax);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);
}
"@
}

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs

$script:NotifyHotkeyLogPath = Join-Path (Get-NotifyBridgeLogDir) 'hotkey.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyHotkeyLogPath) | Out-Null

function Write-NotifyHotkeyLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyHotkeyLogPath -Value $line -Encoding UTF8
}

function Get-NotifyHotkeyFingerprint {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Value).Trim()))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function Unprotect-NotifyHotkeyValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        $protected = [Convert]::FromBase64String($Value)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        Write-NotifyHotkeyLog -Message ('popup-state-unprotect-error "{0}"' -f $_.Exception.Message)
        return ''
    }
}

function Test-NotifyHotkeyCommandLineContainsPath {
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

function Test-NotifyHotkeyPopupProcessOwned {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return $false }
    try {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -eq $process) { return $false }
        $commandLine = [string]$process.CommandLine
        return (($commandLine -like '*pi-notify-popup.ps1*' -or $commandLine -like '*pi-notify-broker.ps1*') -and (Test-NotifyHotkeyCommandLineContainsPath -CommandLine $commandLine -Path $config.ConfigPath))
    }
    catch {
        return $false
    }
}

function Get-NotifyHotkeyLivePopupStates {
    $rows = @()
    $logDir = Get-NotifyBridgeLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { return @($rows) }

    $configFingerprint = Get-NotifyHotkeyFingerprint -Value $config.ConfigPath
    $nowTicks = [DateTime]::UtcNow.Ticks
    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'popup-live.*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $state = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $pidValue = 0
            if (-not ($state.PSObject.Properties['processId']) -or -not [int]::TryParse([string]$state.processId, [ref]$pidValue)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $expiresAtTicks = [int64]0
            if ($state.PSObject.Properties['expiresAtTicks'] -and [int64]::TryParse([string]$state.expiresAtTicks, [ref]$expiresAtTicks) -and $expiresAtTicks -lt $nowTicks) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            if (-not (Test-NotifyHotkeyPopupProcessOwned -ProcessId $pidValue)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            if ($state.PSObject.Properties['configFingerprint'] -and ([string]$state.configFingerprint) -ne $configFingerprint) {
                continue
            }

            $targetHost = if ($state.PSObject.Properties['protectedHost']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedHost) } else { '' }
            $cwdBase = if ($state.PSObject.Properties['protectedCwd']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedCwd) } else { '' }
            $tabTitle = if ($state.PSObject.Properties['protectedTab']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedTab) } else { '' }
            if ([string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle)) {
                continue
            }

            $startedAtTicks = [int64]$item.CreationTimeUtc.Ticks
            if ($state.PSObject.Properties['startedAtTicks']) {
                [int64]::TryParse([string]$state.startedAtTicks, [ref]$startedAtTicks) | Out-Null
            }
            $stackIndex = -1
            if ($state.PSObject.Properties['stackIndex']) {
                [int]::TryParse([string]$state.stackIndex, [ref]$stackIndex) | Out-Null
            }
            $targetFingerprint = if ($state.PSObject.Properties['targetFingerprint']) { [string]$state.targetFingerprint } else { Get-NotifyHotkeyFingerprint -Value $targetHost }
            $brokerManaged = $false
            if ($state.PSObject.Properties['brokerManaged']) { $brokerManaged = [bool]$state.brokerManaged }
            $popupId = if ($state.PSObject.Properties['popupId']) { [string]$state.popupId } else { '' }

            $rows += [pscustomobject]@{
                ProcessId         = $pidValue
                Path              = $item.FullName
                TargetHost        = $targetHost
                CwdBase           = $cwdBase
                TabTitle          = $tabTitle
                TargetFingerprint = $targetFingerprint
                StackIndex        = $stackIndex
                StartedAtTicks    = $startedAtTicks
                BrokerManaged     = $brokerManaged
                PopupId           = $popupId
            }
        }
        catch {
            Write-NotifyHotkeyLog -Message ('popup-state-read-error fileFingerprint={0} "{1}"' -f (Get-NotifyHotkeyFingerprint -Value $item.Name), $_.Exception.Message)
        }
    }

    return @($rows | Sort-Object StartedAtTicks, StackIndex, ProcessId)
}

function Start-NotifyHotkeyActivation {
    param(
        [Parameter(Mandatory = $true)]
        $PopupState
    )

    $activationScript = Join-Path (Get-NotifyBridgeBinDir) 'pi-notify-activate.ps1'
    if (-not (Test-Path -LiteralPath $activationScript)) {
        $activationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
    }
    if (-not (Test-Path -LiteralPath $activationScript)) {
        Write-NotifyHotkeyLog -Message 'activate-missing-script'
        return $false
    }

    $arguments = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $activationScript,
        '-ConfigPath', $config.ConfigPath
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-NotifyBridgePowerShellExe
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['PI_NOTIFY_FOCUS_TARGET'] = [string]$PopupState.TargetHost
    $startInfo.EnvironmentVariables['PI_NOTIFY_CWD_BASE'] = [string]$PopupState.CwdBase
    $startInfo.EnvironmentVariables['PI_NOTIFY_TAB_TITLE'] = [string]$PopupState.TabTitle

    $hasCwd = -not [string]::IsNullOrWhiteSpace([string]$PopupState.CwdBase)
    $hasTab = -not [string]::IsNullOrWhiteSpace([string]$PopupState.TabTitle)
    $brokerManaged = [bool]$PopupState.BrokerManaged
    Write-NotifyHotkeyLog -Message ('activate-oldest pid={0} targetFingerprint={1} hasCwd={2} hasTab={3} stackIndex={4} brokerManaged={5}' -f $PopupState.ProcessId, $PopupState.TargetFingerprint, $hasCwd, $hasTab, $PopupState.StackIndex, $brokerManaged)

    if ($brokerManaged) {
        $brokerCloseUrl = $null
        if ($config.PSObject.Properties['BrokerCloseUrl']) { $brokerCloseUrl = [string]$config.BrokerCloseUrl }
        elseif ($config.PSObject.Properties['BrokerPort']) {
            $brokerCloseUrl = ('http://127.0.0.1:{0}/close' -f [int]$config.BrokerPort)
        }
        if ([string]::IsNullOrWhiteSpace($brokerCloseUrl) -or [string]::IsNullOrWhiteSpace([string]$PopupState.PopupId)) {
            Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
            return $false
        }
        try {
            $closePayload = ('{{"popupId":"{0}","activate":true}}' -f ([string]$PopupState.PopupId))
            $closeBytes = [System.Text.Encoding]::UTF8.GetBytes($closePayload)
            $closeReq = [System.Net.HttpWebRequest]::Create($brokerCloseUrl)
            $closeReq.Method = 'POST'
            $closeReq.ContentType = 'application/json; charset=utf-8'
            $closeReq.ContentLength = $closeBytes.Length
            $closeReq.Timeout = 2000
            $closeReq.ReadWriteTimeout = 2000
            $closeStream = $closeReq.GetRequestStream()
            try { $closeStream.Write($closeBytes, 0, $closeBytes.Length) } finally { $closeStream.Close() }
            $closeResp = $closeReq.GetResponse()
            try { } finally { $closeResp.Close() }
            Write-NotifyHotkeyLog -Message ('broker-popup-activate-request popupId={0}' -f $PopupState.PopupId)
            return $true
        }
        catch {
            Write-NotifyHotkeyLog -Message ('broker-popup-activate-request-error popupId={0} "{1}"' -f $PopupState.PopupId, $_.Exception.Message)
            return $false
        }
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { return $false }

    $completed = $process.WaitForExit(8000)
    if (-not $completed) {
        Write-NotifyHotkeyLog -Message ('activate-timeout pid={0} activationPid={1}' -f $PopupState.ProcessId, $process.Id)
        return $false
    }

    if ($process.ExitCode -eq 0) {
        if ($brokerManaged) {
            # Broker-managed popups: do NOT kill the broker process; ask the broker to close this popup card.
            $brokerCloseUrl = $null
            if ($config.PSObject.Properties['BrokerCloseUrl']) { $brokerCloseUrl = [string]$config.BrokerCloseUrl }
            elseif ($config.PSObject.Properties['BrokerPort']) {
                $brokerCloseUrl = ('http://127.0.0.1:{0}/close' -f [int]$config.BrokerPort)
            }
            if (-not [string]::IsNullOrWhiteSpace($brokerCloseUrl) -and -not [string]::IsNullOrWhiteSpace([string]$PopupState.PopupId)) {
                try {
                    $closePayload = ('{{"popupId":"{0}"}}' -f ([string]$PopupState.PopupId))
                    $closeBytes = [System.Text.Encoding]::UTF8.GetBytes($closePayload)
                    $closeReq = [System.Net.HttpWebRequest]::Create($brokerCloseUrl)
                    $closeReq.Method = 'POST'
                    $closeReq.ContentType = 'application/json; charset=utf-8'
                    $closeReq.ContentLength = $closeBytes.Length
                    $closeReq.Timeout = 2000
                    $closeReq.ReadWriteTimeout = 2000
                    $closeStream = $closeReq.GetRequestStream()
                    try { $closeStream.Write($closeBytes, 0, $closeBytes.Length) } finally { $closeStream.Close() }
                    $closeResp = $closeReq.GetResponse()
                    try { } finally { $closeResp.Close() }
                    Write-NotifyHotkeyLog -Message ('broker-popup-close-after-activate popupId={0}' -f $PopupState.PopupId)
                }
                catch {
                    Write-NotifyHotkeyLog -Message ('broker-popup-close-after-activate-error popupId={0} "{1}"' -f $PopupState.PopupId, $_.Exception.Message)
                    # Fallback: remove the live-state file so the stale popup is not re-activated
                    Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            try {
                Stop-Process -Id ([int]$PopupState.ProcessId) -Force -ErrorAction Stop
                Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
                Write-NotifyHotkeyLog -Message ('popup-close-after-activate pid={0}' -f $PopupState.ProcessId)
            }
            catch {
                Write-NotifyHotkeyLog -Message ('popup-close-after-activate-error pid={0} "{1}"' -f $PopupState.ProcessId, $_.Exception.Message)
            }
        }
        return $true
    }

    Write-NotifyHotkeyLog -Message ('activate-failed pid={0} exitCode={1}' -f $PopupState.ProcessId, $process.ExitCode)
    return $false
}

function Invoke-NotifyHotkeyOldestPopup {
    $states = @(Get-NotifyHotkeyLivePopupStates)
    if ($states.Count -eq 0) {
        Write-NotifyHotkeyLog -Message 'hotkey-no-live-popups'
        return $false
    }

    return (Start-NotifyHotkeyActivation -PopupState $states[0])
}

function ConvertTo-NotifyHotkeyRegistration {
    param([string]$HotkeyValue)

    $value = if ([string]::IsNullOrWhiteSpace($HotkeyValue)) { 'Ctrl+{' } else { [string]$HotkeyValue }
    $parts = @($value -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -lt 2) {
        throw ('Invalid popupHotkey "{0}". Use Ctrl+{{, Alt+P, Ctrl+P, Ctrl+Alt+P, Shift+F8, or Win+P style syntax.' -f $value)
    }

    $modifiers = [uint32]0x4000 # MOD_NOREPEAT
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        switch -Regex ($parts[$i].ToLowerInvariant()) {
            '^(ctrl|control)$' { $modifiers = $modifiers -bor [uint32]0x0002; continue }
            '^alt$' { $modifiers = $modifiers -bor [uint32]0x0001; continue }
            '^shift$' { $modifiers = $modifiers -bor [uint32]0x0004; continue }
            '^(win|windows|meta)$' { $modifiers = $modifiers -bor [uint32]0x0008; continue }
            default { throw ('Unsupported popupHotkey modifier "{0}" in "{1}".' -f $parts[$i], $value) }
        }
    }

    $key = $parts[$parts.Count - 1].ToUpperInvariant()
    $virtualKey = [uint32]0
    $requiresShift = $false
    if ($key.Length -eq 1) {
        $ch = [char]$key[0]
        if ((($ch -ge [char]'A') -and ($ch -le [char]'Z')) -or (($ch -ge [char]'0') -and ($ch -le [char]'9'))) {
            $virtualKey = [uint32][byte][char]$ch
        }
        else {
            switch ($key) {
                '[' { $virtualKey = [uint32]0xDB; break }
                '{' { $virtualKey = [uint32]0xDB; $requiresShift = $true; break }
                ']' { $virtualKey = [uint32]0xDD; break }
                '}' { $virtualKey = [uint32]0xDD; $requiresShift = $true; break }
                '\' { $virtualKey = [uint32]0xDC; break }
                '|' { $virtualKey = [uint32]0xDC; $requiresShift = $true; break }
                ';' { $virtualKey = [uint32]0xBA; break }
                ':' { $virtualKey = [uint32]0xBA; $requiresShift = $true; break }
                "'" { $virtualKey = [uint32]0xDE; break }
                '"' { $virtualKey = [uint32]0xDE; $requiresShift = $true; break }
                ',' { $virtualKey = [uint32]0xBC; break }
                '<' { $virtualKey = [uint32]0xBC; $requiresShift = $true; break }
                '.' { $virtualKey = [uint32]0xBE; break }
                '>' { $virtualKey = [uint32]0xBE; $requiresShift = $true; break }
                '/' { $virtualKey = [uint32]0xBF; break }
                '?' { $virtualKey = [uint32]0xBF; $requiresShift = $true; break }
                '`' { $virtualKey = [uint32]0xC0; break }
                '~' { $virtualKey = [uint32]0xC0; $requiresShift = $true; break }
                '-' { $virtualKey = [uint32]0xBD; break }
                '_' { $virtualKey = [uint32]0xBD; $requiresShift = $true; break }
                '=' { $virtualKey = [uint32]0xBB; break }
            }
        }
    }
    elseif ($key -match '^F([1-9]|1[0-9]|2[0-4])$') {
        $virtualKey = [uint32](0x70 + [int]$Matches[1] - 1)
    }
    if ($requiresShift) {
        $modifiers = $modifiers -bor [uint32]0x0004
    }
    if ($virtualKey -eq 0) {
        throw ('Unsupported popupHotkey key "{0}" in "{1}".' -f $key, $value)
    }
    if (($modifiers -band 0x000F) -eq 0) {
        throw ('popupHotkey must include at least one modifier: {0}' -f $value)
    }

    [pscustomobject]@{
        Label      = ($parts -join '+')
        Modifiers  = $modifiers
        VirtualKey = $virtualKey
    }
}

function Start-NotifyHotkeyResident {
    if ($config.PSObject.Properties['PopupHotkeyEnabled'] -and -not [bool]$config.PopupHotkeyEnabled) {
        Write-NotifyHotkeyLog -Message 'resident-disabled'
        return 0
    }

    $registration = ConvertTo-NotifyHotkeyRegistration -HotkeyValue ([string]$config.PopupHotkey)
    $mutexName = 'Local\PiNotifyHotkey-{0}' -f (Get-NotifyHotkeyFingerprint -Value $config.ConfigPath)
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-NotifyHotkeyLog -Message ('resident-existing hotkey={0}' -f $registration.Label)
        return 0
    }

    $id = 0x5050
    $registered = $false
    try {
        $registered = [PiNotifyHotkeyNative]::RegisterHotKey([IntPtr]::Zero, $id, [uint32]$registration.Modifiers, [uint32]$registration.VirtualKey)
        if (-not $registered) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-NotifyHotkeyLog -Message ('resident-register-failed hotkey={0} error={1}' -f $registration.Label, $errorCode)
            return 1
        }
        Write-NotifyHotkeyLog -Message ('resident-start hotkey={0} modifiers=0x{1:x} vk=0x{2:x}' -f $registration.Label, [uint32]$registration.Modifiers, [uint32]$registration.VirtualKey)
        $lastHotkeyAtTicks = [int64]0
        $debounceTicks = [TimeSpan]::FromMilliseconds(1000).Ticks
        $msg = [PiNotifyHotkeyNative+MSG]::new()
        while ($true) {
            $result = [PiNotifyHotkeyNative]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)
            if ($result -eq 0) { break }
            if ($result -lt 0) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-NotifyHotkeyLog -Message ('resident-getmessage-error error={0}' -f $errorCode)
                return 1
            }
            if ($msg.message -eq 0x0312 -and $msg.wParam.ToInt32() -eq $id) {
                $nowTicks = [DateTime]::UtcNow.Ticks
                if ($lastHotkeyAtTicks -gt 0 -and ($nowTicks - $lastHotkeyAtTicks) -lt $debounceTicks) {
                    Write-NotifyHotkeyLog -Message 'resident-debounce'
                }
                else {
                    $lastHotkeyAtTicks = $nowTicks
                    try {
                        [void](Invoke-NotifyHotkeyOldestPopup)
                    }
                    catch {
                        Write-NotifyHotkeyLog -Message ('resident-activate-error "{0}"' -f $_.Exception.Message)
                    }
                }
            }
            [void][PiNotifyHotkeyNative]::TranslateMessage([ref]$msg)
            [void][PiNotifyHotkeyNative]::DispatchMessage([ref]$msg)
        }
        return 0
    }
    finally {
        if ($registered) { [void][PiNotifyHotkeyNative]::UnregisterHotKey([IntPtr]::Zero, $id) }
        if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
        Write-NotifyHotkeyLog -Message ('resident-stop hotkey={0}' -f $registration.Label)
    }
}

if ($Once) {
    if (Invoke-NotifyHotkeyOldestPopup) { exit 0 }
    exit 1
}

exit (Start-NotifyHotkeyResident)
